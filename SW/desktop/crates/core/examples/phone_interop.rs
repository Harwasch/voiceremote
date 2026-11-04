//! Synthetic process-pair harness, not a network listener or product entry point.
//! Inputs: Swift Noise packets on stdin. Verified by NoiseInteropTests on Linux/macOS.
use async_trait::async_trait;
use std::io::{self, BufRead, Write};
use voiceremote_core::{
    Result, TextInjector, ensure,
    pairing::{self, Clock, Offer},
    protocol::*,
    session::Delivery,
    storage::{FileKeyStore, Identity, Registry},
    transport::Transport,
};

struct Stdio;
fn output(kind: &str, value: &str) -> Result<()> {
    println!("{kind}:{value}");
    io::stdout().flush()?;
    Ok(())
}
#[async_trait]
impl Transport for Stdio {
    async fn send(&mut self, packet: &[u8]) -> Result<()> {
        output("packet", &hex::encode(packet))
    }
    async fn recv(&mut self) -> Result<Vec<u8>> {
        let mut line = String::new();
        ensure!(
            io::stdin().lock().read_line(&mut line)? > 0,
            "phone disconnected"
        );
        let value = line
            .trim_end()
            .strip_prefix("packet:")
            .ok_or_else(|| anyhow::anyhow!("expected packet"))?;
        ensure!(value.len() <= 131070, "packet bound");
        Ok(hex::decode(value)?)
    }
    async fn close(&mut self) -> Result<()> {
        Ok(())
    }
}
struct FixedClock;
impl Clock for FixedClock {
    fn now_ms(&self) -> Result<u64> {
        Ok(1)
    }
}
struct Sink;
impl TextInjector for Sink {
    fn insert_text(&mut self, _: &str) -> Result<()> {
        Ok(())
    }
}
fn info() -> DeviceInfo {
    DeviceInfo {
        kind: DeviceInfoKind::DeviceInfo,
        account_id: "synthetic".into(),
        device_id: "desktop".into(),
        display_name: "Synthetic desktop".into(),
        platform: DeviceInfoPlatform::Linux,
        role: DeviceInfoRole::TextReceiver,
        capabilities: vec![Capability::ReceiveText],
    }
}
#[tokio::main(worker_threads = 2)]
async fn main() -> Result<()> {
    let from_phone = std::env::args().any(|a| a == "--revoke-from-phone");
    let temp = tempfile::tempdir()?;
    let registry = Registry::new(std::sync::Arc::new(FileKeyStore::new(
        temp.path().join("keys"),
    )?));
    let identity = Identity::generate()?;
    let mut offer = Offer::issue(
        &identity,
        "synthetic".into(),
        "synthetic-room".into(),
        &FixedClock,
    )?;
    output(
        "qr",
        &hex::encode(encode(&offer.payload).map_err(anyhow::Error::msg)?),
    )?;
    let mut transport = Stdio;
    let mut pending = pairing::accept(&mut transport, &identity, &mut offer, &FixedClock).await?;
    let phrase = pending.phrase();
    output("phrase", &phrase)?;
    pending
        .confirm_local(&mut transport, &phrase, info())
        .await?;
    pending.receive_confirmation(&mut transport).await?;
    let mut session = pending.finish(registry.clone())?;
    // Full-sized Unicode messages force independently authenticated fragments in
    // both directions, through the real desktop Session send/receive boundary.
    let incoming = session.receive(&mut transport).await?;
    let InnerMessage::DictationText(mut text) = incoming.clone() else {
        anyhow::bail!("dictation expected")
    };
    ensure!(text.text == "🦀".repeat(16384), "Unicode payload mismatch");
    ensure!(
        session.deliver(&mut transport, incoming, &mut Sink).await? == Delivery::Inserted,
        "not inserted"
    );
    text.target_device_id = "phone".into();
    session
        .send(&mut transport, &InnerMessage::DictationText(text))
        .await?;
    let peer = session.peer().clone();
    // Same carrier, new handshake and nonce state; requires existing enrollment.
    let mut session =
        pairing::resume_accept(&mut transport, &identity, &registry, &peer, "desktop").await?;
    let message = session.receive(&mut transport).await?;
    ensure!(
        matches!(message, InnerMessage::DeviceInfo(_)),
        "resumed application missing"
    );
    session
        .send(&mut transport, &InnerMessage::DeviceInfo(info()))
        .await?;
    if from_phone {
        let revoke = session.receive(&mut transport).await?;
        ensure!(
            session.deliver(&mut transport, revoke, &mut Sink).await? == Delivery::Revoked,
            "revocation failed"
        );
        ensure!(session.check_active().is_err(), "revoked session active");
        ensure!(registry.require(&peer).is_err(), "revoked peer retained");
    } else {
        session
            .send(
                &mut transport,
                &InnerMessage::Revoke(Revoke {
                    kind: RevokeKind::Revoke,
                    account_id: "synthetic".into(),
                    device_id: "phone".into(),
                    command_id: "synthetic-revoke".into(),
                    idempotency_key: "synthetic-idempotency".into(),
                    revoked_at: 1,
                }),
            )
            .await?;
    }
    output("done", "handshake phrase fragments resume revoke verified")
}
