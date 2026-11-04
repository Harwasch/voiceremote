//! Desktop session polling needs cancellation-safe raw packet reception.
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

    #[tokio::test(start_paused = true)]
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
                        ciphertext: B64.encode(
                            [b"VRR1\x06".as_slice(), &[42; 32], &[0; 32], &[1, 2, 3]].concat(),
                        ),
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
        transport.retained_session();
        for _ in 0..2 {
            assert!(
                tokio::time::timeout(Duration::from_secs(4), transport.recv())
                    .await
                    .is_err()
            );
        }
        let packet = tokio::time::timeout(Duration::from_secs(3), transport.recv()).await??;
        assert_eq!(packet, [1, 2, 3]);
        server.await??;
        Ok(())
    }
}

// Reuse the core VRR1 relay codec, freshness filters and persistent keepalive.
#[cfg(test)]
use base64::{Engine, engine::general_purpose::STANDARD as B64};
#[cfg(test)]
use futures_util::{SinkExt, StreamExt};
#[cfg(test)]
use tokio_tungstenite::tungstenite::Message;
pub use voiceremote_core::transport::RelayTransport;
#[cfg(test)]
use voiceremote_core::{protocol::*, transport::RelayRoute};

/// Select by the peer's first Noise packet, not by which listener opens first.
/// One Offer is then consumed on exactly one path by the pairing state machine.
pub async fn accept_pairing(
    listener: Option<&LanListener>,
    client: Option<&voiceremote_core::relay::RelayClient>,
) -> Result<(Box<dyn Transport>, bool)> {
    struct Staged {
        packet: Option<Vec<u8>>,
        inner: Box<dyn Transport>,
    }
    #[async_trait::async_trait]
    impl Transport for Staged {
        async fn send(&mut self, packet: &[u8]) -> Result<()> {
            self.inner.send(packet).await
        }
        async fn recv(&mut self) -> Result<Vec<u8>> {
            if let Some(packet) = self.packet.take() {
                Ok(packet)
            } else {
                self.inner.recv().await
            }
        }
        async fn close(&mut self) -> Result<()> {
            self.inner.close().await
        }
    }
    async fn stage(
        mut inner: Box<dyn Transport>,
        relay: bool,
    ) -> Result<(Box<dyn Transport>, bool)> {
        let packet = inner.recv().await?;
        Ok((
            Box::new(Staged {
                packet: Some(packet),
                inner,
            }),
            relay,
        ))
    }
    let lan = async {
        let Some(listener) = listener else {
            return std::future::pending().await;
        };
        stage(Box::new(listener.accept().await?), false).await
    };
    let relay = async {
        let Some(client) = client else {
            return std::future::pending().await;
        };
        stage(Box::new(RelayTransport::connect(client).await?), true).await
    };
    tokio::pin!(lan, relay);
    tokio::select! {
        result = &mut lan => match result { Ok(value) => Ok(value), Err(error) if client.is_none() => Err(error), Err(_) => relay.await },
        result = &mut relay => match result { Ok(value) => Ok(value), Err(error) if listener.is_none() => Err(error), Err(_) => lan.await },
    }
}
