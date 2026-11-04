//! Phone initiates XX; desktop responds. See SYS/protocol/noise.md.
use crate::{
    Result, ensure,
    protocol::*,
    session::Session,
    storage::{Identity, Registry},
    transport::Transport,
};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use rand::{RngCore, rngs::OsRng};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

pub const PATTERN: &str = "Noise_XX_25519_ChaChaPoly_BLAKE2s";
pub fn noise_builder<'a>() -> Result<snow::Builder<'a>> {
    crate::crypto::builder()
}
pub const TOKEN_TTL_MS: u64 = 120_000;
pub const MAX_NOISE: usize = 65_535;
pub trait Clock: Send + Sync {
    fn now_ms(&self) -> Result<u64>;
}
pub struct SystemClock;
impl Clock for SystemClock {
    fn now_ms(&self) -> Result<u64> {
        Ok(SystemTime::now()
            .duration_since(UNIX_EPOCH)?
            .as_millis()
            .try_into()?)
    }
}

pub struct Offer {
    pub payload: PairingPayload,
    issued: Instant,
    used: bool,
    lifetime: Duration,
}
impl Offer {
    pub fn issue(
        identity: &Identity,
        account: String,
        room: String,
        clock: &dyn Clock,
    ) -> Result<Self> {
        let now = clock.now_ms()?;
        let mut token = Zeroizing::new([0u8; 32]);
        OsRng.fill_bytes(token.as_mut());
        let payload = PairingPayload {
            kind: PairingPayloadKind::Pairing,
            account_id: account,
            desktop_public_key: B64.encode(&identity.public),
            one_use_token: B64.encode(*token),
            expires_at: now
                .checked_add(TOKEN_TTL_MS)
                .ok_or_else(|| crate::anyhow!("clock overflow"))?,
            relay_room_id: room,
        };
        encode(&payload).map_err(anyhow::Error::msg)?;
        Ok(Self {
            payload,
            issued: Instant::now(),
            used: false,
            lifetime: Duration::from_millis(TOKEN_TTL_MS),
        })
    }
    pub fn from_relay_invite(
        identity: &Identity,
        account: String,
        room: String,
        token: String,
        expires_at: u64,
        clock: &dyn Clock,
    ) -> Result<Self> {
        let payload = PairingPayload {
            kind: PairingPayloadKind::Pairing,
            account_id: account,
            desktop_public_key: B64.encode(&identity.public),
            one_use_token: token,
            expires_at,
            relay_room_id: room,
        };
        validate_offer(&payload, clock)?;
        let lifetime = Duration::from_millis(expires_at - clock.now_ms()?);
        Ok(Self {
            payload,
            issued: Instant::now(),
            used: false,
            lifetime,
        })
    }
    fn check_valid(&self, clock: &dyn Clock) -> Result<()> {
        ensure!(!self.used, "enrollment token already used");
        validate_offer(&self.payload, clock)?;
        ensure!(
            self.issued.elapsed() < self.lifetime,
            "issuer enrollment deadline elapsed"
        );
        Ok(())
    }
    fn remaining(&self) -> Duration {
        self.lifetime.saturating_sub(self.issued.elapsed())
    }
    fn redeem(&mut self, token: &[u8], clock: &dyn Clock) -> Result<()> {
        self.check_valid(clock)?;
        let expected = Zeroizing::new(B64.decode(&self.payload.one_use_token)?);
        ensure!(
            bool::from(expected.as_slice().ct_eq(token)),
            "invalid enrollment token"
        );
        // Consume before phrase confirmation, including on later abort.
        self.used = true;
        self.payload.one_use_token.zeroize();
        Ok(())
    }
}

pub fn validate_offer(payload: &PairingPayload, clock: &dyn Clock) -> Result<()> {
    encode(payload).map_err(anyhow::Error::msg)?;
    ensure!(
        B64.decode(&payload.desktop_public_key)?.len() == 32,
        "invalid desktop key size"
    );
    ensure!(
        B64.decode(&payload.one_use_token)?.len() == 32,
        "invalid token size"
    );
    let remaining = payload.expires_at.checked_sub(clock.now_ms()?).unwrap_or(0);
    ensure!(
        remaining > 0 && remaining <= TOKEN_TTL_MS,
        "expired or far-future enrollment"
    );
    Ok(())
}

/// Fixed, language-independent prologue. Never serialize JSON to obtain this.
pub fn prologue(payload: &PairingPayload) -> Result<Vec<u8>> {
    let mut bytes = b"voiceremote/pair/v1\0".to_vec();
    for value in [&payload.account_id, &payload.relay_room_id] {
        bytes.extend_from_slice(&(value.len() as u32).to_be_bytes());
        bytes.extend_from_slice(value.as_bytes());
    }
    bytes.extend_from_slice(&B64.decode(&payload.desktop_public_key)?);
    bytes.extend_from_slice(&payload.expires_at.to_be_bytes());
    Ok(bytes)
}

/// Four words encode the first 32 handshake-hash bits as four 8-bit indices.
/// Each dictionary word is the concatenation of a high-nibble prefix and low-nibble suffix.
pub fn verification_phrase(hash: &[u8]) -> String {
    const PREFIX: [&str; 16] = [
        "amber", "birch", "cedar", "dawn", "elm", "fern", "gold", "hazel", "iris", "jade", "kelp",
        "lunar", "maple", "north", "oak", "pine",
    ];
    const SUFFIX: [&str; 16] = [
        "ant", "bird", "cat", "deer", "elk", "fox", "goat", "hare", "ibis", "jay", "kite", "lynx",
        "moth", "newt", "owl", "puma",
    ];
    hash.iter()
        .take(4)
        .map(|b| format!("{}{}", PREFIX[(b >> 4) as usize], SUFFIX[(b & 15) as usize]))
        .collect::<Vec<_>>()
        .join(" ")
}

pub struct PendingPair {
    state: snow::TransportState,
    hash: Vec<u8>,
    remote_key: Vec<u8>,
    account: String,
    room: String,
    local: Option<DeviceInfo>,
    remote: Option<DeviceInfo>,
    aborted: bool,
}
impl PendingPair {
    fn from_handshake(state: snow::HandshakeState, payload: &PairingPayload) -> Result<Self> {
        let hash = state.get_handshake_hash().to_vec();
        let remote_key = state
            .get_remote_static()
            .ok_or_else(|| crate::anyhow!("missing peer key"))?
            .to_vec();
        Ok(Self {
            state: state.into_transport_mode()?,
            hash,
            remote_key,
            account: payload.account_id.clone(),
            room: payload.relay_room_id.clone(),
            local: None,
            remote: None,
            aborted: false,
        })
    }
    pub fn phrase(&self) -> String {
        verification_phrase(&self.hash)
    }
    pub fn remote_info(&self) -> Option<&DeviceInfo> {
        self.remote.as_ref()
    }
    pub fn handshake_hash(&self) -> &[u8] {
        &self.hash
    }
    /// Call only from trusted local UI after the human compared both displays.
    pub async fn confirm_local(
        &mut self,
        transport: &mut dyn Transport,
        displayed_phrase: &str,
        info: DeviceInfo,
    ) -> Result<()> {
        ensure!(
            !self.aborted && self.local.is_none(),
            "pairing already confirmed or aborted"
        );
        if displayed_phrase != self.phrase() {
            self.aborted = true;
            transport.close().await?;
            crate::bail!("phrase mismatch");
        }
        ensure!(
            info.account_id == self.account,
            "cross-account confirmation"
        );
        let encoded = encode(&info).map_err(anyhow::Error::msg)?;
        let mut plain = vec![1];
        plain.extend_from_slice(&self.hash);
        plain.extend_from_slice(encoded.as_bytes());
        let mut packet = vec![0; MAX_NOISE];
        self.aborted = true; // Never retry a possibly consumed send nonce.
        let n = self.state.write_message(&plain, &mut packet)?;
        transport.send(&packet[..n]).await?;
        self.local = Some(info);
        self.aborted = false;
        Ok(())
    }
    pub async fn receive_confirmation(&mut self, transport: &mut dyn Transport) -> Result<()> {
        ensure!(
            !self.aborted && self.remote.is_none(),
            "pairing already confirmed or aborted"
        );
        // A malformed, early application message or negative confirmation poisons enrollment.
        self.aborted = true;
        let packet = transport.recv().await?;
        let mut plain = vec![0; MAX_NOISE];
        let n = self.state.read_message(&packet, &mut plain)?;
        ensure!(
            n > 33 && plain[0] == 1 && plain[1..33] == self.hash,
            "invalid confirmation"
        );
        let info: DeviceInfo =
            decode(std::str::from_utf8(&plain[33..n])?).map_err(anyhow::Error::msg)?;
        ensure!(info.account_id == self.account, "cross-account peer");
        self.remote = Some(info);
        self.aborted = false;
        Ok(())
    }
    pub fn finish(self, registry: Registry) -> Result<Session> {
        ensure!(
            !self.aborted && self.local.is_some() && self.remote.is_some(),
            "both confirmations required"
        );
        let local = self.local.unwrap();
        let remote = self.remote.unwrap();
        ensure!(
            local.device_id != remote.device_id,
            "duplicate device identity"
        );
        registry.remember_local(&local)?;
        let peer = registry.enroll(self.remote_key, self.room, remote)?;
        Ok(Session::new(self.state, registry, peer, local.device_id))
    }
}

pub const HANDSHAKE_STEP_TIMEOUT: Duration = Duration::from_secs(10);
async fn step_receive(transport: &mut dyn Transport) -> Result<Vec<u8>> {
    tokio::time::timeout(HANDSHAKE_STEP_TIMEOUT, transport.recv()).await?
}
async fn step_send(transport: &mut dyn Transport, bytes: &[u8]) -> Result<()> {
    tokio::time::timeout(HANDSHAKE_STEP_TIMEOUT, transport.send(bytes)).await?
}

pub async fn accept(
    transport: &mut dyn Transport,
    identity: &Identity,
    offer: &mut Offer,
    clock: &dyn Clock,
) -> Result<PendingPair> {
    offer.check_valid(clock)?;
    // Waiting for a scan is bounded by enrollment lifetime, not a handshake step.
    let first = tokio::time::timeout(offer.remaining(), transport.recv()).await??;
    offer.check_valid(clock)?;
    let context = prologue(&offer.payload)?;
    let mut state = noise_builder()?
        .local_private_key(identity.private())?
        .prologue(&context)?
        .build_responder()?;
    let mut plain = Zeroizing::new(vec![0; MAX_NOISE]);
    let mut packet = vec![0; MAX_NOISE];
    ensure!(
        state.read_message(&first, &mut plain)? == 0,
        "message 1 payload forbidden"
    );
    let n = state.write_message(&[], &mut packet)?;
    step_send(transport, &packet[..n]).await?;
    let n = state.read_message(&step_receive(transport).await?, &mut plain)?;
    offer.redeem(&plain[..n], clock)?;
    PendingPair::from_handshake(state, &offer.payload)
}

pub async fn initiate(
    transport: &mut dyn Transport,
    identity: &Identity,
    payload: &PairingPayload,
    clock: &dyn Clock,
) -> Result<PendingPair> {
    tokio::time::timeout(Duration::from_secs(30), async {
        validate_offer(payload, clock)?;
        let context = prologue(payload)?;
        let mut state = noise_builder()?
            .local_private_key(identity.private())?
            .prologue(&context)?
            .build_initiator()?;
        let mut packet = vec![0; MAX_NOISE];
        let mut plain = vec![0; MAX_NOISE];
        let n = state.write_message(&[], &mut packet)?;
        transport.send(&packet[..n]).await?;
        let n = state.read_message(&transport.recv().await?, &mut plain)?;
        ensure!(
            n == 0
                && state.get_remote_static()
                    == Some(B64.decode(&payload.desktop_public_key)?.as_slice()),
            "QR key mismatch"
        );
        validate_offer(payload, clock)?;
        let token = Zeroizing::new(B64.decode(&payload.one_use_token)?);
        let n = state.write_message(&token, &mut packet)?;
        transport.send(&packet[..n]).await?;
        PendingPair::from_handshake(state, payload)
    })
    .await?
}

fn resume_prologue(account: &str, room: &str) -> Vec<u8> {
    let mut bytes = b"voiceremote/session/v1\0".to_vec();
    for value in [account, room] {
        bytes.extend_from_slice(&(value.len() as u32).to_be_bytes());
        bytes.extend_from_slice(value.as_bytes());
    }
    bytes
}
/// Reconnect authenticates an already-enrolled static key; it cannot enroll one.
pub async fn resume_accept(
    transport: &mut dyn Transport,
    identity: &Identity,
    registry: &Registry,
    peer: &crate::storage::Peer,
    local_device: &str,
) -> Result<Session> {
    registry.require(peer)?;
    let first = transport.recv().await?; // Receiver may wait indefinitely for phone.
    registry.require(peer)?;
    tokio::time::timeout(HANDSHAKE_STEP_TIMEOUT, async {
        let context = resume_prologue(&peer.info.account_id, &peer.room);
        let mut state = noise_builder()?
            .local_private_key(identity.private())?
            .prologue(&context)?
            .build_responder()?;
        let mut plain = vec![0; MAX_NOISE];
        let mut packet = vec![0; MAX_NOISE];
        ensure!(
            state.read_message(&first, &mut plain)? == 0,
            "unexpected reconnect payload"
        );
        let n = state.write_message(&[], &mut packet)?;
        transport.send(&packet[..n]).await?;
        ensure!(
            state.read_message(&transport.recv().await?, &mut plain)? == 0,
            "unexpected reconnect payload"
        );
        ensure!(
            state.get_remote_static() == Some(peer.public_key.as_slice()),
            "unregistered static key"
        );
        registry.require(peer)?;
        let mut ready = vec![2];
        ready.extend_from_slice(state.get_handshake_hash());
        let mut state = state.into_transport_mode()?;
        let n = state.write_message(&ready, &mut packet)?;
        transport.send(&packet[..n]).await?;
        Ok(Session::new(
            state,
            registry.clone(),
            peer.clone(),
            local_device.into(),
        ))
    })
    .await?
}
pub async fn resume_initiate(
    transport: &mut dyn Transport,
    identity: &Identity,
    registry: &Registry,
    peer: &crate::storage::Peer,
    local_device: &str,
) -> Result<Session> {
    tokio::time::timeout(Duration::from_secs(30), async {
        registry.require(peer)?;
        let context = resume_prologue(&peer.info.account_id, &peer.room);
        let mut state = noise_builder()?
            .local_private_key(identity.private())?
            .prologue(&context)?
            .build_initiator()?;
        let mut packet = vec![0; MAX_NOISE];
        let mut plain = vec![0; MAX_NOISE];
        let n = state.write_message(&[], &mut packet)?;
        transport.send(&packet[..n]).await?;
        ensure!(
            state.read_message(&transport.recv().await?, &mut plain)? == 0,
            "unexpected reconnect payload"
        );
        ensure!(
            state.get_remote_static() == Some(peer.public_key.as_slice()),
            "unregistered static key"
        );
        let n = state.write_message(&[], &mut packet)?;
        transport.send(&packet[..n]).await?;
        let hash = state.get_handshake_hash().to_vec();
        let mut state = state.into_transport_mode()?;
        let n = state.read_message(&transport.recv().await?, &mut plain)?;
        ensure!(
            n == 33 && plain[0] == 2 && plain[1..33] == hash,
            "missing reconnect acceptance"
        );
        registry.require(peer)?;
        Ok(Session::new(
            state,
            registry.clone(),
            peer.clone(),
            local_device.into(),
        ))
    })
    .await?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn monotonic_expiry_survives_wall_clock_rollback() -> Result<()> {
        struct ClockAt(u64);
        impl Clock for ClockAt {
            fn now_ms(&self) -> Result<u64> {
                Ok(self.0)
            }
        }
        let identity = Identity::generate()?;
        let mut offer = Offer::issue(
            &identity,
            "synthetic-account".into(),
            "synthetic-room".into(),
            &ClockAt(1000),
        )?;
        let token = B64.decode(&offer.payload.one_use_token)?;
        offer.issued = Instant::now() - Duration::from_millis(TOKEN_TTL_MS);
        assert!(offer.redeem(&token, &ClockAt(1001)).is_err());
        Ok(())
    }
}
