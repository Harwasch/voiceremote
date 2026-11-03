//! One message boundary for LAN TCP and relay WebSocket; security is in Noise.
use crate::{Result, ensure, protocol::*};
use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::{
    net::{IpAddr, SocketAddr},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async_with_config,
    tungstenite::{Message, client::IntoClientRequest, protocol::WebSocketConfig},
};

#[async_trait]
pub trait Transport: Send {
    async fn send(&mut self, packet: &[u8]) -> Result<()>;
    async fn recv(&mut self) -> Result<Vec<u8>>;
    async fn close(&mut self) -> Result<()>;
}

pub fn lan_address(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_private() || ip.is_loopback() || ip.is_link_local(),
        IpAddr::V6(ip) => ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local(),
    }
}

/// Prefer physical Wi-Fi/Ethernet names and routable private addresses;
/// exclude known virtual/tunnel prefixes. --listen remains an explicit override.
pub fn select_named_interface(interfaces: &[(String, IpAddr)]) -> Result<IpAddr> {
    let mut usable: Vec<_> = interfaces
        .iter()
        .filter(|(name, ip)| {
            let name = name.to_ascii_lowercase();
            lan_address(*ip)
                && !ip.is_loopback()
                && ![
                    "docker",
                    "veth",
                    "br-",
                    "virbr",
                    "tailscale",
                    "tun",
                    "tap",
                    "wg",
                    "zt",
                    "vmnet",
                    "vbox",
                    "vethernet",
                ]
                .iter()
                .any(|prefix| name.starts_with(prefix))
        })
        .collect();
    usable.sort_by_key(|(name, ip)| {
        let physical = ["wl", "en", "eth", "wi-fi", "ethernet"]
            .iter()
            .any(|prefix| name.to_ascii_lowercase().starts_with(prefix));
        let link_local = match ip {
            IpAddr::V4(v) => v.is_link_local(),
            IpAddr::V6(v) => v.is_unicast_link_local(),
        };
        (!physical, link_local, !ip.is_ipv4(), name.clone(), *ip)
    });
    usable
        .first()
        .map(|(_, ip)| *ip)
        .ok_or_else(|| crate::anyhow!("no usable non-virtual LAN interface; use --listen or relay"))
}

pub struct LanTransport {
    stream: TcpStream,
}
impl LanTransport {
    pub async fn connect(address: SocketAddr) -> Result<Self> {
        ensure!(
            lan_address(address.ip()),
            "LAN connection requires a private address"
        );
        let stream =
            tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(address)).await??;
        Self::from_stream(stream)
    }
    pub fn from_stream(stream: TcpStream) -> Result<Self> {
        ensure!(
            lan_address(stream.local_addr()?.ip()) && lan_address(stream.peer_addr()?.ip()),
            "non-LAN socket"
        );
        stream.set_nodelay(true)?;
        let socket = socket2::SockRef::from(&stream);
        let keepalive = socket2::TcpKeepalive::new()
            .with_time(Duration::from_secs(10))
            .with_interval(Duration::from_secs(5));
        socket.set_tcp_keepalive(&keepalive)?;
        Ok(Self { stream })
    }
}
#[async_trait]
impl Transport for LanTransport {
    async fn send(&mut self, packet: &[u8]) -> Result<()> {
        ensure!(
            !packet.is_empty() && packet.len() <= crate::pairing::MAX_NOISE,
            "invalid packet length"
        );
        tokio::time::timeout(Duration::from_secs(10), async {
            self.stream.write_u32(packet.len() as u32).await?;
            self.stream.write_all(packet).await?;
            self.stream.flush().await?;
            Ok::<_, anyhow::Error>(())
        })
        .await?
    }
    async fn recv(&mut self) -> Result<Vec<u8>> {
        let n = self.stream.read_u32().await? as usize;
        ensure!(
            n > 0 && n <= crate::pairing::MAX_NOISE,
            "invalid packet length"
        );
        let mut packet = vec![0; n];
        self.stream.read_exact(&mut packet).await?;
        Ok(packet)
    }
    async fn close(&mut self) -> Result<()> {
        Ok(self.stream.shutdown().await?)
    }
}

pub const SERVICE: &str = "_voiceremote._tcp.local.";
/// Binds only the caller-selected private interface, never a wildcard/public IP.
/// Drop shuts down discovery and closes the listener; no firewall/router changes.
pub struct LanListener {
    listener: TcpListener,
    mdns: Option<ServiceDaemon>,
}
impl LanListener {
    /// Default LAN path: select a configured private interface without IP entry.
    pub async fn bind_auto() -> Result<Self> {
        let addresses: Vec<_> = if_addrs::get_if_addrs()?
            .into_iter()
            .map(|i| (i.name.clone(), i.ip()))
            .collect();
        let ip = select_named_interface(&addresses)?;
        Self::bind(SocketAddr::new(ip, 0)).await
    }

    pub async fn bind(address: SocketAddr) -> Result<Self> {
        ensure!(
            lan_address(address.ip()) && !address.ip().is_unspecified(),
            "select a private LAN interface"
        );
        Ok(Self {
            listener: TcpListener::bind(address).await?,
            mdns: None,
        })
    }
    pub fn address(&self) -> Result<SocketAddr> {
        Ok(self.listener.local_addr()?)
    }
    pub fn advertise(&mut self, room: &str) -> Result<()> {
        let address = self.address()?;
        let daemon = ServiceDaemon::new()?;
        let instance = format!(
            "vr-{}",
            &hex::encode(sha2::Sha256::digest(room.as_bytes()))[..16]
        );
        let properties = [("room", room), ("version", "1")];
        let info = ServiceInfo::new(
            SERVICE,
            &instance,
            &format!("{instance}.local."),
            address.ip(),
            address.port(),
            &properties[..],
        )?;
        daemon.register(info)?;
        self.mdns = Some(daemon);
        Ok(())
    }
    pub async fn accept(&self) -> Result<LanTransport> {
        LanTransport::from_stream(self.listener.accept().await?.0)
    }
}
impl Drop for LanListener {
    fn drop(&mut self) {
        if let Some(daemon) = &self.mdns {
            let _ = daemon.shutdown();
        }
    }
}
use sha2::Digest;

pub async fn discover(room: &str, timeout: Duration) -> Result<Vec<SocketAddr>> {
    let daemon = ServiceDaemon::new()?;
    let events = daemon.browse(SERVICE)?;
    let result = tokio::time::timeout(timeout, async {
        loop {
            if let ServiceEvent::ServiceResolved(info) = events.recv_async().await? {
                if info.get_property_val_str("room") == Some(room) {
                    let addresses = info
                        .get_addresses()
                        .iter()
                        .filter(|ip| lan_address(**ip))
                        .map(|ip| SocketAddr::new(*ip, info.get_port()))
                        .collect::<Vec<_>>();
                    if !addresses.is_empty() {
                        return Ok(addresses);
                    }
                }
            }
        }
    })
    .await;
    let _ = daemon.shutdown();
    result?
}

#[derive(Clone)]
pub struct RelayRoute {
    pub account: String,
    pub room: String,
    pub sender: String,
}

pub struct RelayTransport {
    socket: WebSocketStream<MaybeTlsStream<TcpStream>>,
    route: RelayRoute,
}
impl RelayTransport {
    pub async fn connect(client: &crate::relay::RelayClient) -> Result<Self> {
        let request = client.connect_request().await?;
        Self::from_request(request, client.route.clone()).await
    }
    /// Loopback-only entry for in-process fake relay tests, never a WAN fallback.
    pub async fn connect_loopback(endpoint: &str, route: RelayRoute) -> Result<Self> {
        let request = endpoint.into_client_request()?;
        let host = request.uri().host().unwrap_or("");
        ensure!(
            request.uri().scheme_str() == Some("ws") && matches!(host, "127.0.0.1" | "[::1]"),
            "fake relay requires loopback"
        );
        Self::from_request(request, route).await
    }
    async fn from_request(
        request: tokio_tungstenite::tungstenite::http::Request<()>,
        route: RelayRoute,
    ) -> Result<Self> {
        let (socket, _) = tokio::time::timeout(
            Duration::from_secs(10),
            connect_async_with_config(
                request,
                Some(
                    WebSocketConfig::default()
                        .max_message_size(Some(crate::relay::FRAME_BYTES))
                        .max_frame_size(Some(crate::relay::FRAME_BYTES)),
                ),
                true,
            ),
        )
        .await??;
        let mut transport = Self { socket, route };
        transport.presence(RelayPresenceState::Online).await?;
        Ok(transport)
    }
    async fn presence(&mut self, state: RelayPresenceState) -> Result<()> {
        let frame = RelayPresence {
            kind: RelayPresenceKind::Presence,
            account_id: self.route.account.clone(),
            room_id: self.route.room.clone(),
            sender_device_id: self.route.sender.clone(),
            state,
        };
        let encoded = encode(&frame).map_err(anyhow::Error::msg)?;
        ensure!(
            encoded.len() <= crate::relay::FRAME_BYTES,
            "relay frame exceeds worker cap"
        );
        tokio::time::timeout(
            Duration::from_secs(10),
            self.socket.send(Message::Text(encoded.into())),
        )
        .await??;
        Ok(())
    }
}
#[async_trait]
impl Transport for RelayTransport {
    async fn send(&mut self, packet: &[u8]) -> Result<()> {
        ensure!(
            !packet.is_empty() && packet.len() <= crate::pairing::MAX_NOISE,
            "invalid packet length"
        );
        let frame = RelayCiphertext {
            kind: RelayCiphertextKind::Ciphertext,
            account_id: self.route.account.clone(),
            room_id: self.route.room.clone(),
            sender_device_id: self.route.sender.clone(),
            ciphertext: B64.encode(packet),
        };
        let encoded = encode(&frame).map_err(anyhow::Error::msg)?;
        ensure!(
            encoded.len() <= crate::relay::FRAME_BYTES,
            "relay frame exceeds worker cap"
        );
        tokio::time::timeout(
            Duration::from_secs(10),
            self.socket.send(Message::Text(encoded.into())),
        )
        .await??;
        Ok(())
    }
    async fn recv(&mut self) -> Result<Vec<u8>> {
        let mut ping = tokio::time::interval_at(
            tokio::time::Instant::now() + Duration::from_secs(10),
            Duration::from_secs(10),
        );
        let mut last_seen = tokio::time::Instant::now();
        loop {
            let message = tokio::select! {
                message=self.socket.next()=>message.ok_or_else(||crate::anyhow!("relay disconnected"))??,
                _=ping.tick()=>{
                    ensure!(last_seen.elapsed()<Duration::from_secs(30),"relay keepalive timed out");
                    tokio::time::timeout(Duration::from_secs(5),self.socket.send(Message::Ping(Vec::new().into()))).await??;continue;
                },
            };
            last_seen = tokio::time::Instant::now();
            match message {
                Message::Text(text) => {
                    ensure!(
                        text.len() <= crate::relay::FRAME_BYTES,
                        "oversize relay frame"
                    );
                    let frame: RelayFrame = decode(&text).map_err(anyhow::Error::msg)?;
                    match frame {
                        RelayFrame::RelayCiphertext(frame) => {
                            ensure!(
                                frame.account_id == self.route.account
                                    && frame.room_id == self.route.room
                                    && frame.sender_device_id != self.route.sender,
                                "relay route mismatch"
                            );
                            let bytes = B64.decode(frame.ciphertext)?;
                            ensure!(
                                !bytes.is_empty() && bytes.len() <= crate::pairing::MAX_NOISE,
                                "invalid ciphertext size"
                            );
                            return Ok(bytes);
                        }
                        RelayFrame::RelayPresence(frame) => ensure!(
                            frame.account_id == self.route.account
                                && frame.room_id == self.route.room,
                            "relay presence route mismatch"
                        ),
                        _ => crate::bail!("unexpected relay metadata"),
                    }
                }
                Message::Ping(data) => self.socket.send(Message::Pong(data)).await?,
                Message::Pong(_) => {}
                Message::Close(_) => crate::bail!("relay closed"),
                _ => crate::bail!("relay requires text frames"),
            }
        }
    }
    async fn close(&mut self) -> Result<()> {
        let _ = self.presence(RelayPresenceState::Offline).await;
        Ok(self.socket.close(None).await?)
    }
}
