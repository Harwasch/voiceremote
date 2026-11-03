//! Windows session polling needs cancellation-safe raw packet reception.
//! Core's LAN read_exact receiver cannot be cancelled between header/body reads.
//! This adapter retains framing progress in the transport across focus polls.
use anyhow::{Result, ensure};
use mdns_sd::{ServiceDaemon, ServiceInfo};
use sha2::{Digest, Sha256};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use voiceremote_core::{
    pairing::MAX_NOISE,
    transport::{SERVICE, Transport, lan_address, select_named_interface},
};

pub struct LanTransport {
    stream: TcpStream,
    header: [u8; 4],
    header_used: usize,
    body: Vec<u8>,
    body_used: usize,
}
impl LanTransport {
    fn new(stream: TcpStream) -> Result<Self> {
        ensure!(
            lan_address(stream.local_addr()?.ip()) && lan_address(stream.peer_addr()?.ip()),
            "non-LAN socket"
        );
        stream.set_nodelay(true)?;
        socket2::SockRef::from(&stream).set_tcp_keepalive(
            &socket2::TcpKeepalive::new()
                .with_time(Duration::from_secs(10))
                .with_interval(Duration::from_secs(5)),
        )?;
        Ok(Self {
            stream,
            header: [0; 4],
            header_used: 0,
            body: Vec::new(),
            body_used: 0,
        })
    }
}
#[async_trait::async_trait]
impl Transport for LanTransport {
    async fn send(&mut self, packet: &[u8]) -> Result<()> {
        ensure!(
            !packet.is_empty() && packet.len() <= MAX_NOISE,
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
        while self.header_used < 4 {
            let n = self
                .stream
                .read(&mut self.header[self.header_used..])
                .await?;
            ensure!(n > 0, "LAN disconnected in packet header");
            self.header_used += n;
        }
        if self.body.is_empty() {
            let n = u32::from_be_bytes(self.header) as usize;
            ensure!(n > 0 && n <= MAX_NOISE, "invalid packet length");
            self.body.resize(n, 0);
        }
        while self.body_used < self.body.len() {
            let n = self.stream.read(&mut self.body[self.body_used..]).await?;
            ensure!(n > 0, "LAN disconnected in packet body");
            self.body_used += n;
        }
        self.header_used = 0;
        self.body_used = 0;
        Ok(std::mem::take(&mut self.body))
    }
    async fn close(&mut self) -> Result<()> {
        Ok(self.stream.shutdown().await?)
    }
}
pub struct LanListener {
    listener: TcpListener,
    mdns: Option<ServiceDaemon>,
}
impl LanListener {
    pub async fn bind_auto() -> Result<Self> {
        let interfaces = if_addrs::get_if_addrs()?
            .into_iter()
            .map(|i| (i.name.clone(), i.ip()))
            .collect::<Vec<_>>();
        Self::bind(SocketAddr::new(select_named_interface(&interfaces)?, 0)).await
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
        let digest = Sha256::digest(room.as_bytes());
        let instance = format!(
            "vr-{}",
            digest[..8]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
        let properties = [("room", room), ("version", "1")];
        daemon.register(ServiceInfo::new(
            SERVICE,
            &instance,
            &format!("{instance}.local."),
            address.ip(),
            address.port(),
            &properties[..],
        )?)?;
        self.mdns = Some(daemon);
        Ok(())
    }
    pub async fn accept(&self) -> Result<LanTransport> {
        LanTransport::new(self.listener.accept().await?.0)
    }
}
impl Drop for LanListener {
    fn drop(&mut self) {
        if let Some(daemon) = &self.mdns {
            let _ = daemon.shutdown();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn focus_poll_cancellation_preserves_partial_header_and_body() {
        let listener = LanListener::bind("127.0.0.1:0".parse().unwrap())
            .await
            .unwrap();
        let mut sender = TcpStream::connect(listener.address().unwrap())
            .await
            .unwrap();
        let mut receiver = listener.accept().await.unwrap();
        sender.write_all(&[0, 0]).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(20), receiver.recv())
                .await
                .is_err()
        );
        sender.write_all(&[0, 4, 1, 2]).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(20), receiver.recv())
                .await
                .is_err()
        );
        sender.write_all(&[3, 4, 0, 0, 0, 1, 9]).await.unwrap();
        assert_eq!(receiver.recv().await.unwrap(), [1, 2, 3, 4]);
        assert_eq!(receiver.recv().await.unwrap(), [9]);
    }
    #[tokio::test]
    async fn rejects_zero_and_oversized_frames_before_allocating() {
        for length in [0, MAX_NOISE as u32 + 1] {
            let listener = LanListener::bind("127.0.0.1:0".parse().unwrap())
                .await
                .unwrap();
            let mut sender = TcpStream::connect(listener.address().unwrap())
                .await
                .unwrap();
            let mut receiver = listener.accept().await.unwrap();
            sender.write_u32(length).await.unwrap();
            assert!(receiver.recv().await.is_err());
            assert!(receiver.body.is_empty());
        }
    }

    #[tokio::test]
    async fn focus_polls_preserve_relay_ping_deadline_and_ciphertext() -> Result<()> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let endpoint = format!("ws://{}", listener.local_addr()?);
        let server = tokio::spawn(async move {
            let mut socket = tokio_tungstenite::accept_async(listener.accept().await?.0).await?;
            // connect_loopback publishes online presence before returning.
            let _ = socket.next().await;
            loop {
                if let Some(Ok(Message::Ping(_))) = socket.next().await {
                    let frame = RelayCiphertext {
                        kind: RelayCiphertextKind::Ciphertext,
                        account_id: "synthetic-account".into(),
                        room_id: "synthetic-room".into(),
                        sender_device_id: "phone".into(),
                        ciphertext: B64.encode([1, 2, 3]),
                    };
                    socket
                        .send(Message::Text(
                            encode(&frame).map_err(anyhow::Error::msg)?.into(),
                        ))
                        .await?;
                    return Ok::<_, anyhow::Error>(());
                }
            }
        });
        let mut transport = RelayTransport::connect_loopback(
            &endpoint,
            RelayRoute {
                account: "synthetic-account".into(),
                room: "synthetic-room".into(),
                sender: "desktop".into(),
            },
        )
        .await?;
        transport.ping = tokio::time::interval_at(
            tokio::time::Instant::now() + Duration::from_millis(100),
            Duration::from_millis(100),
        );
        for _ in 0..3 {
            assert!(
                tokio::time::timeout(Duration::from_millis(10), transport.recv())
                    .await
                    .is_err()
            );
        }
        let packet = tokio::time::timeout(Duration::from_secs(2), transport.recv()).await??;
        assert_eq!(packet, [1, 2, 3]);
        server.await??;
        Ok(())
    }
}

// Same wire/TLS/route checks as core RelayTransport. Timers live on the
// transport, so focus polls cannot reset keepalive or cancel partial frames.
use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
#[cfg(test)]
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async_with_config,
    tungstenite::{Message, protocol::WebSocketConfig},
};
use voiceremote_core::{protocol::*, transport::RelayRoute};
pub struct RelayTransport {
    socket: WebSocketStream<MaybeTlsStream<TcpStream>>,
    route: RelayRoute,
    ping: tokio::time::Interval,
    last_seen: tokio::time::Instant,
}
impl RelayTransport {
    pub async fn connect(client: &voiceremote_core::relay::RelayClient) -> Result<Self> {
        let request = client.connect_request().await?;
        Self::from_request(request, client.route.clone()).await
    }
    /// Loopback-only entry for in-process fake relay tests, never a WAN fallback.
    #[cfg(test)]
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
                        .max_message_size(Some(voiceremote_core::relay::FRAME_BYTES))
                        .max_frame_size(Some(voiceremote_core::relay::FRAME_BYTES)),
                ),
                true,
            ),
        )
        .await??;
        let mut transport = Self {
            socket,
            route,
            ping: tokio::time::interval_at(
                tokio::time::Instant::now() + Duration::from_secs(10),
                Duration::from_secs(10),
            ),
            last_seen: tokio::time::Instant::now(),
        };
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
            encoded.len() <= voiceremote_core::relay::FRAME_BYTES,
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
            !packet.is_empty() && packet.len() <= voiceremote_core::pairing::MAX_NOISE,
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
            encoded.len() <= voiceremote_core::relay::FRAME_BYTES,
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
        loop {
            let message = tokio::select! {
                message=self.socket.next()=>message.ok_or_else(||anyhow::anyhow!("relay disconnected"))??,
                _=self.ping.tick()=>{
                    ensure!(self.last_seen.elapsed()<Duration::from_secs(30),"relay keepalive timed out");
                    tokio::time::timeout(Duration::from_secs(5),self.socket.send(Message::Ping(Vec::new().into()))).await??;continue;
                },
            };
            self.last_seen = tokio::time::Instant::now();
            match message {
                Message::Text(text) => {
                    ensure!(
                        text.len() <= voiceremote_core::relay::FRAME_BYTES,
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
                                !bytes.is_empty()
                                    && bytes.len() <= voiceremote_core::pairing::MAX_NOISE,
                                "invalid ciphertext size"
                            );
                            return Ok(bytes);
                        }
                        RelayFrame::RelayPresence(frame) => ensure!(
                            frame.account_id == self.route.account
                                && frame.room_id == self.route.room,
                            "relay presence route mismatch"
                        ),
                        _ => anyhow::bail!("unexpected relay metadata"),
                    }
                }
                Message::Ping(data) => self.socket.send(Message::Pong(data)).await?,
                Message::Pong(_) => {}
                Message::Close(_) => anyhow::bail!("relay closed"),
                _ => anyhow::bail!("relay requires text frames"),
            }
        }
    }
    async fn close(&mut self) -> Result<()> {
        let _ = self.presence(RelayPresenceState::Offline).await;
        Ok(self.socket.close(None).await?)
    }
}
