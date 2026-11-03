//! Relay worker SECURITY.md HTTP contract. Signing keys are distinct from Noise.
use crate::{
    Result, ensure,
    pairing::{Clock, SystemClock},
    storage::KeyStore,
    transport::RelayRoute,
};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signer, SigningKey};
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest,
    http::{HeaderValue, Request},
};
use zeroize::Zeroizing;

pub fn new_room_id() -> String {
    let mut bytes = [0; 16];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}
pub const FRAME_BYTES: usize = 16_384;
/// Conservative packet budget including AEAD; leaves room for three maximum IDs.
pub const PACKET_BYTES: usize = 11_000;
#[derive(Clone)]
pub struct RelayIdentity(SigningKey);
impl RelayIdentity {
    pub fn generate() -> Self {
        let mut seed = Zeroizing::new([0; 32]);
        OsRng.fill_bytes(seed.as_mut());
        Self(SigningKey::from_bytes(&seed))
    }
    pub fn load_or_create(store: &dyn KeyStore) -> Result<Self> {
        if let Some(seed) = store.get("relay-signing")? {
            let seed = Zeroizing::new(<[u8; 32]>::try_from(seed.as_slice())?);
            return Ok(Self(SigningKey::from_bytes(&seed)));
        }
        let identity = Self::generate();
        let seed = Zeroizing::new(identity.0.to_bytes());
        store.put("relay-signing", seed.as_ref())?;
        Ok(identity)
    }
    pub fn public_key(&self) -> String {
        B64.encode(self.0.verifying_key().as_bytes())
    }
    pub fn sign(&self, bytes: &[u8]) -> String {
        B64.encode(self.0.sign(bytes).to_bytes())
    }
}
#[derive(Clone)]
pub struct RelayClient {
    http: reqwest::Client,
    base: String,
    pub route: RelayRoute,
    identity: RelayIdentity,
    server_clock: Arc<Mutex<Option<(u64, Instant)>>>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Challenge {
    challenge: String,
    message: String,
    expires_at: u64,
    server_time: u64,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Invitation {
    pub one_use_token: String,
    pub expires_at: u64,
}

pub fn relay_id(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'),
        "relay identifiers must be ASCII letters/digits/underscore/hyphen"
    );
    Ok(())
}
fn canonical_base64(value: &str, n: usize) -> Result<()> {
    let bytes = B64.decode(value)?;
    ensure!(
        bytes.len() == n && B64.encode(bytes) == value,
        "invalid canonical relay key/token"
    );
    Ok(())
}
pub fn digest(bytes: &[u8]) -> String {
    B64.encode(Sha256::digest(bytes))
}
impl RelayClient {
    pub fn new(origin: &str, route: RelayRoute, identity: RelayIdentity) -> Result<Self> {
        Self::build(origin, route, identity, false)
    }
    pub fn loopback(origin: &str, route: RelayRoute, identity: RelayIdentity) -> Result<Self> {
        Self::build(origin, route, identity, true)
    }
    fn build(origin: &str, route: RelayRoute, identity: RelayIdentity, test: bool) -> Result<Self> {
        for id in [&route.account, &route.room, &route.sender] {
            relay_id(id)?;
        }
        ensure!(
            route.room.len() == 32
                && route
                    .room
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "relay room must be 128-bit lowercase hex"
        );
        let origin = origin
            .replacen("wss://", "https://", 1)
            .replacen("ws://", "http://", 1);
        let url = reqwest::Url::parse(&origin)?;
        ensure!(
            url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none()
                && url.path() == "/",
            "relay config must be an origin without credentials/path/query"
        );
        ensure!(
            url.scheme() == "https"
                || (test
                    && url.scheme() == "http"
                    && matches!(url.host_str(), Some("127.0.0.1" | "[::1]" | "::1"))),
            "relay requires HTTPS/WSS"
        );
        let base = format!(
            "{}/v1/accounts/{}/rooms/{}",
            url.as_str().trim_end_matches('/'),
            route.account,
            route.room
        );
        Ok(Self {
            http: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(10))
                .build()?,
            base,
            route,
            identity,
            server_clock: Arc::new(Mutex::new(None)),
        })
    }
    async fn response(&self, request: reqwest::RequestBuilder) -> Result<String> {
        let mut response = request.send().await?;
        ensure!(
            response.status().is_success(),
            "relay HTTP refusal: {}",
            response.status().as_u16()
        );
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            ensure!(
                bytes.len() + chunk.len() <= 4096,
                "oversized relay control response"
            );
            bytes.extend_from_slice(&chunk);
        }
        Ok(String::from_utf8(bytes)?)
    }
    fn post(&self, operation: &str, body: String) -> reqwest::RequestBuilder {
        self.http
            .post(format!("{}/{operation}", self.base))
            .header("Content-Type", "application/json")
            .body(body)
    }
    /// Signed creation; an optional provisioner secret is used only when the
    /// deployment requires it. Ordinary first-pair rooms need no phone key.
    pub async fn create(&self, provisioner: Option<&str>) -> Result<u64> {
        let body = serde_json::json!({"device_id":self.route.sender,"public_key":self.identity.public_key()}).to_string();
        let proof = serde_json::to_vec(&serde_json::json!([
            "voiceremote-relay-create-v1",
            self.route.account,
            self.route.room,
            digest(body.as_bytes())
        ]))?;
        let mut request = self
            .post("create", body)
            .header("X-Relay-Signature", self.identity.sign(&proof));
        if let Some(secret) = provisioner {
            request = request.bearer_auth(secret);
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Created {
            created: bool,
            server_time: u64,
            expires_at: u64,
        }
        let created: Created = serde_json::from_str(&self.response(request).await?)?;
        ensure!(
            created.created
                && created.expires_at <= 9_007_199_254_740_991
                && created.expires_at > created.server_time
                && created.expires_at - created.server_time <= 120_000,
            "invalid creation lifetime"
        );
        *self
            .server_clock
            .lock()
            .map_err(|_| crate::anyhow!("clock lock"))? =
            Some((created.server_time, Instant::now()));
        Ok(created.expires_at)
    }
    pub async fn bootstrap(&self, provisioning_secret: &str) -> Result<()> {
        ensure!(
            provisioning_secret.len() >= 32,
            "provisioning secret too short"
        );
        self.create(Some(provisioning_secret)).await?;
        Ok(())
    }
    async fn authorization(&self, operation: &str, body: &str) -> Result<(String, String)> {
        let body_hash = digest(body.as_bytes());
        let request_body=serde_json::json!({"device_id":self.route.sender,"operation":operation,"body_sha256":body_hash}).to_string();
        let proof = serde_json::to_vec(&serde_json::json!([
            "voiceremote-relay-challenge-v1",
            self.route.account,
            self.route.room,
            digest(request_body.as_bytes())
        ]))?;
        let started = Instant::now();
        let response = self
            .response(
                self.post("challenge", request_body)
                    .header("X-Relay-Signature", self.identity.sign(&proof)),
            )
            .await?;
        let challenge: Challenge = serde_json::from_str(&response)?;
        canonical_base64(&challenge.challenge, 32)?;
        ensure!(
            challenge.expires_at <= 9_007_199_254_740_991
                && challenge.expires_at > challenge.server_time
                && challenge.expires_at - challenge.server_time <= 60_000
                && started.elapsed()
                    < Duration::from_millis(challenge.expires_at - challenge.server_time),
            "expired/future relay challenge"
        );
        *self
            .server_clock
            .lock()
            .map_err(|_| crate::anyhow!("clock lock"))? =
            Some((challenge.server_time, Instant::now()));
        let expected = serde_json::json!([
            "voiceremote-relay-auth-v1",
            self.route.account,
            self.route.room,
            self.route.sender,
            operation,
            body_hash,
            challenge.challenge,
            challenge.expires_at
        ])
        .to_string();
        ensure!(
            challenge.message == expected,
            "relay challenge context mismatch"
        );
        Ok((challenge.challenge, self.identity.sign(expected.as_bytes())))
    }
    async fn signed_post(&self, operation: &str, body: String) -> Result<String> {
        let (nonce, signature) = self.authorization(operation, &body).await?;
        self.response(
            self.post(operation, body)
                .header("X-Relay-Challenge", nonce)
                .header("X-Relay-Signature", signature),
        )
        .await
    }
    pub async fn invite(&self) -> Result<Invitation> {
        // An existing room obtains server time with a *consumed* connect proof,
        // rather than leaking unused challenges and exhausting their two slots.
        let known = self
            .server_clock
            .lock()
            .map_err(|_| crate::anyhow!("clock lock"))?
            .is_some();
        if !known {
            use crate::transport::Transport;
            crate::transport::RelayTransport::connect(self)
                .await?
                .close()
                .await?;
        }
        let (server_time, observed) = self
            .server_clock
            .lock()
            .map_err(|_| crate::anyhow!("clock lock"))?
            .ok_or_else(|| crate::anyhow!("server clock unavailable"))?;
        ensure!(
            observed.elapsed() < Duration::from_secs(60),
            "refresh server time before invitation"
        );
        let expires_at = server_time + observed.elapsed().as_millis() as u64 + 120_000;
        let mut token = Zeroizing::new([0; 32]);
        OsRng.fill_bytes(token.as_mut());
        let one_use_token = B64.encode(*token);
        let raw = self.signed_post("invite",serde_json::json!({"token_sha256":digest(one_use_token.as_bytes()),"expires_at":expires_at}).to_string()).await?;
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Registered {
            registered: bool,
            expires_at: u64,
        }
        let registered: Registered = serde_json::from_str(&raw)?;
        ensure!(
            registered.registered && registered.expires_at == expires_at,
            "invitation context mismatch"
        );
        Ok(Invitation {
            one_use_token,
            expires_at,
        })
    }
    pub async fn join(&self, invitation: &Invitation) -> Result<()> {
        canonical_base64(&invitation.one_use_token, 32)?;
        let remaining = invitation.expires_at.saturating_sub(SystemClock.now_ms()?);
        ensure!(
            remaining > 0 && remaining <= 120_000,
            "expired relay invitation"
        );
        let key = self.identity.public_key();
        let message = serde_json::json!([
            "voiceremote-relay-join-v1",
            self.route.account,
            self.route.room,
            self.route.sender,
            key,
            invitation.one_use_token,
            invitation.expires_at
        ])
        .to_string();
        self.response(self.post("join",serde_json::json!({"device_id":self.route.sender,"public_key":key,"one_use_token":invitation.one_use_token,"expires_at":invitation.expires_at,"signature":self.identity.sign(message.as_bytes())}).to_string())).await?;
        Ok(())
    }
    pub async fn revoke(&self, device: &str) -> Result<()> {
        relay_id(device)?;
        self.signed_post(
            "revoke",
            serde_json::json!({"device_id":device}).to_string(),
        )
        .await?;
        Ok(())
    }
    pub async fn connect_request(&self) -> Result<Request<()>> {
        let (nonce, signature) = self.authorization("connect", "").await?;
        let url = format!("{}/connect", self.base)
            .replacen("https://", "wss://", 1)
            .replacen("http://", "ws://", 1);
        let mut request = url.into_client_request()?;
        request
            .headers_mut()
            .insert("X-Relay-Challenge", HeaderValue::from_str(&nonce)?);
        request
            .headers_mut()
            .insert("X-Relay-Signature", HeaderValue::from_str(&signature)?);
        Ok(request)
    }
}
