//! Bounded full-duplex packet pumps; Session receives only when a packet is ready.
//! No pending Session::receive future is cancelled to deliver a task status.
use anyhow::{Result, ensure};
use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use futures_util::{SinkExt, StreamExt};
use sha2::{Digest, Sha256};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::{mpsc, oneshot},
    task::JoinHandle,
};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{Message, protocol::WebSocketConfig},
};
use voiceremote_core::{
    protocol::*,
    relay::{FRAME_BYTES, PACKET_BYTES, RelayClient},
    transport::{SERVICE, Transport, lan_address, select_named_interface},
};
const IO_TIMEOUT: Duration = Duration::from_secs(10);
enum Outgoing {
    Packet(Vec<u8>, oneshot::Sender<Result<()>>),
    Socket(Message),
    Close(oneshot::Sender<Result<()>>),
}
pub struct PacketTransport {
    incoming: mpsc::Receiver<Result<Vec<u8>>>,
    outgoing: mpsc::Sender<Outgoing>,
    pending: Option<Vec<u8>>,
    reader: JoinHandle<()>,
    writer: JoinHandle<()>,
}
impl Drop for PacketTransport {
    fn drop(&mut self) {
        self.reader.abort();
        self.writer.abort();
    }
}
impl PacketTransport {
    /// Cancellation-safe readiness: only bounded-channel reads, never raw framing.
    pub async fn readable(&mut self) -> Result<()> {
        if self.pending.is_none() {
            self.pending = Some(
                self.incoming
                    .recv()
                    .await
                    .ok_or_else(|| anyhow::anyhow!("transport closed"))??,
            );
        }
        Ok(())
    }
    pub fn from_tcp(stream: TcpStream) -> Result<Self> {
        ensure!(
            lan_address(stream.local_addr()?.ip()) && lan_address(stream.peer_addr()?.ip()),
            "private LAN required"
        );
        stream.set_nodelay(true)?;
        socket2::SockRef::from(&stream).set_tcp_keepalive(
            &socket2::TcpKeepalive::new()
                .with_time(Duration::from_secs(10))
                .with_interval(Duration::from_secs(5)),
        )?;
        let (mut read, mut write) = stream.into_split();
        let (input, incoming) = mpsc::channel(4);
        let (outgoing, mut output) = mpsc::channel(4);
        let reader = tokio::spawn(async move {
            loop {
                let packet = async {
                    let n = read.read_u32().await? as usize;
                    ensure!(n > 0 && n <= PACKET_BYTES, "invalid frame length");
                    let mut bytes = vec![0; n];
                    tokio::time::timeout(IO_TIMEOUT, read.read_exact(&mut bytes)).await??;
                    Ok(bytes)
                }
                .await;
                let failed = packet.is_err();
                if input.send(packet).await.is_err() || failed {
                    break;
                }
            }
        });
        let writer = tokio::spawn(async move {
            while let Some(message) = output.recv().await {
                match message {
                    Outgoing::Packet(packet, ack) => {
                        let result = async {
                            write.write_u32(packet.len() as u32).await?;
                            write.write_all(&packet).await?;
                            write.flush().await?;
                            Ok(())
                        }
                        .await;
                        let failed = result.is_err();
                        let _ = ack.send(result);
                        if failed {
                            break;
                        }
                    }
                    Outgoing::Close(ack) => {
                        let _ = ack.send(write.shutdown().await.map_err(Into::into));
                        break;
                    }
                    _ => break,
                }
            }
        });
        Ok(Self {
            incoming,
            outgoing,
            pending: None,
            reader,
            writer,
        })
    }
    pub async fn connect_relay(client: &RelayClient) -> Result<Self> {
        Self::from_relay_request(client.connect_request().await?, client.route.clone()).await
    }
    /// Synthetic relay tests only; never an insecure WAN path.
    pub async fn connect_loopback(
        endpoint: &str,
        route: voiceremote_core::transport::RelayRoute,
    ) -> Result<Self> {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;
        let request = endpoint.into_client_request()?;
        ensure!(
            request.uri().scheme_str() == Some("ws")
                && matches!(request.uri().host(), Some("127.0.0.1" | "[::1]")),
            "loopback fake only"
        );
        Self::from_relay_request(request, route).await
    }
    async fn from_relay_request(
        request: tokio_tungstenite::tungstenite::http::Request<()>,
        route: voiceremote_core::transport::RelayRoute,
    ) -> Result<Self> {
        let (mut socket, _) = tokio::time::timeout(
            IO_TIMEOUT,
            connect_async_with_config(
                request,
                Some(
                    WebSocketConfig::default()
                        .max_message_size(Some(FRAME_BYTES))
                        .max_frame_size(Some(FRAME_BYTES)),
                ),
                true,
            ),
        )
        .await??;
        let presence = RelayPresence {
            kind: RelayPresenceKind::Presence,
            account_id: route.account.clone(),
            room_id: route.room.clone(),
            sender_device_id: route.sender.clone(),
            state: RelayPresenceState::Online,
        };
        socket
            .send(Message::Text(
                encode(&presence).map_err(anyhow::Error::msg)?.into(),
            ))
            .await?;
        let (mut write, mut read) = socket.split();
        let (input, incoming) = mpsc::channel(4);
        let (outgoing, mut output) = mpsc::channel(4);
        let control = outgoing.clone();
        let read_route = route.clone();
        let reader = tokio::spawn(async move {
            let result=async {
                let mut ping=tokio::time::interval_at(tokio::time::Instant::now()+Duration::from_secs(10),Duration::from_secs(10));
                let mut seen=tokio::time::Instant::now();
                loop {
                    let message=tokio::select! {
                        message=read.next()=>message.ok_or_else(||anyhow::anyhow!("relay disconnected"))??,
                        _=ping.tick()=>{
                            ensure!(seen.elapsed()<Duration::from_secs(30),"relay keepalive expired");
                            tokio::time::timeout(IO_TIMEOUT,control.send(Outgoing::Socket(Message::Ping(vec![].into())))).await??;
                            continue;
                        }
                    };
                    seen=tokio::time::Instant::now();
                    match message {
                        Message::Text(text)=>{
                            ensure!(text.len()<=FRAME_BYTES,"oversized relay frame");
                            match decode::<RelayFrame>(&text).map_err(anyhow::Error::msg)? {
                                RelayFrame::RelayCiphertext(frame)=>{
                                    ensure!(frame.account_id==read_route.account && frame.room_id==read_route.room && frame.sender_device_id!=read_route.sender,"relay route mismatch");
                                    let packet=B64.decode(frame.ciphertext)?;
                                    ensure!(!packet.is_empty() && packet.len()<=PACKET_BYTES,"invalid ciphertext size");
                                    input.send(Ok(packet)).await?;
                                },
                                RelayFrame::RelayPresence(frame)=>ensure!(frame.account_id==read_route.account && frame.room_id==read_route.room,"presence route mismatch"),
                                _=>anyhow::bail!("unexpected relay metadata"),
                            }
                        },
                        Message::Ping(data)=>{control.send(Outgoing::Socket(Message::Pong(data))).await?;},
                        Message::Pong(_)=>{},
                        _=>anyhow::bail!("relay closed or invalid frame"),
                    }
                }
                #[allow(unreachable_code)] Ok::<(),anyhow::Error>(())
            }.await;
            if let Err(error) = result {
                let _ = input.send(Err(error)).await;
            }
        });
        let writer = tokio::spawn(async move {
            while let Some(message) = output.recv().await {
                match message {
                    Outgoing::Packet(packet, ack) => {
                        let result = async {
                            let frame = RelayCiphertext {
                                kind: RelayCiphertextKind::Ciphertext,
                                account_id: route.account.clone(),
                                room_id: route.room.clone(),
                                sender_device_id: route.sender.clone(),
                                ciphertext: B64.encode(packet),
                            };
                            let text = encode(&frame).map_err(anyhow::Error::msg)?;
                            ensure!(text.len() <= FRAME_BYTES, "relay frame bound");
                            write.send(Message::Text(text.into())).await?;
                            Ok(())
                        }
                        .await;
                        let failed = result.is_err();
                        let _ = ack.send(result);
                        if failed {
                            break;
                        }
                    }
                    Outgoing::Socket(message) => {
                        if write.send(message).await.is_err() {
                            break;
                        }
                    }
                    Outgoing::Close(ack) => {
                        let _ = ack.send(write.close().await.map_err(Into::into));
                        break;
                    }
                }
            }
        });
        Ok(Self {
            incoming,
            outgoing,
            pending: None,
            reader,
            writer,
        })
    }
}
#[async_trait]
impl Transport for PacketTransport {
    async fn send(&mut self, packet: &[u8]) -> Result<()> {
        ensure!(
            !packet.is_empty() && packet.len() <= PACKET_BYTES,
            "invalid packet length"
        );
        let (ack, done) = oneshot::channel();
        tokio::time::timeout(IO_TIMEOUT, async {
            self.outgoing
                .send(Outgoing::Packet(packet.to_vec(), ack))
                .await?;
            done.await?
        })
        .await?
    }
    async fn recv(&mut self) -> Result<Vec<u8>> {
        self.readable().await?;
        Ok(self.pending.take().unwrap())
    }
    async fn close(&mut self) -> Result<()> {
        let (ack, done) = oneshot::channel();
        let result = tokio::time::timeout(Duration::from_secs(1), async {
            self.outgoing.send(Outgoing::Close(ack)).await?;
            done.await?
        })
        .await?;
        self.reader.abort();
        self.writer.abort();
        result
    }
}
pub struct Listener {
    listener: TcpListener,
    mdns: Option<mdns_sd::ServiceDaemon>,
}
impl Listener {
    pub async fn bind(address: SocketAddr) -> Result<Self> {
        ensure!(
            lan_address(address.ip()) && !address.ip().is_unspecified(),
            "private LAN interface required"
        );
        Ok(Self {
            listener: TcpListener::bind(address).await?,
            mdns: None,
        })
    }
    pub async fn bind_auto() -> Result<Self> {
        let interfaces = if_addrs::get_if_addrs()?
            .into_iter()
            .map(|i| (i.name.clone(), i.ip()))
            .collect::<Vec<_>>();
        Self::bind(SocketAddr::new(select_named_interface(&interfaces)?, 0)).await
    }
    pub fn address(&self) -> Result<SocketAddr> {
        Ok(self.listener.local_addr()?)
    }
    pub fn advertise(&mut self, room: &str) -> Result<()> {
        let address = self.address()?;
        let daemon = mdns_sd::ServiceDaemon::new()?;
        let instance = format!("vr-{}", &hex::encode(Sha256::digest(room.as_bytes()))[..16]);
        daemon.register(mdns_sd::ServiceInfo::new(
            SERVICE,
            &instance,
            &format!("{instance}.local."),
            address.ip(),
            address.port(),
            &[("room", room), ("version", "1")][..],
        )?)?;
        self.mdns = Some(daemon);
        Ok(())
    }
    pub async fn accept(&self) -> Result<PacketTransport> {
        PacketTransport::from_tcp(self.listener.accept().await?.0)
    }
}
impl Drop for Listener {
    fn drop(&mut self) {
        if let Some(daemon) = &self.mdns {
            let _ = daemon.shutdown();
        }
    }
}
