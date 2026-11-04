//! Independent in-process fake of the relay worker SECURITY.md auth boundary.
//! Synthetic keys only; no permissive bearer upgrade. Includes actual XX traffic.
use axum::{
    Router,
    body::Bytes,
    extract::{
        Path, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::any,
};
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use ed25519_dalek::{Signature, VerifyingKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{net::TcpListener, sync::mpsc, task::JoinHandle};
use voiceremote_core::{
    Result, TextInjector,
    pairing::{self, Clock, Offer, SystemClock},
    protocol::*,
    relay::{RelayClient, RelayIdentity},
    storage::{Identity, KeyStore, Registry},
    transport::{RelayRoute, RelayTransport, Transport},
};
use zeroize::Zeroizing;

const SECRET: &str = "synthetic-bootstrap-secret-at-least-32";
#[derive(Clone)]
struct Member {
    key: String,
}
struct Invite {
    expires: u64,
}
struct Challenge {
    device: String,
    op: String,
    digest: String,
    message: String,
    expires: u64,
}
#[derive(Default)]
struct Room {
    members: HashMap<String, Member>,
    invites: HashMap<String, Invite>,
    challenges: HashMap<String, Challenge>,
}
#[derive(Default)]
struct Data {
    rooms: HashMap<(String, String), Room>,
    sockets: HashMap<(String, String, String), mpsc::UnboundedSender<Message>>,
    serial: u64,
    connects: usize,
    frames: usize,
    max_frame: usize,
    bad_context: bool,
    clock_offset: u64,
    challenge_lifetime: i64,
}
type Shared = Arc<Mutex<Data>>;
fn hash(bytes: &[u8]) -> String {
    B64.encode(Sha256::digest(bytes))
}
fn verify(key: &str, signature: &str, message: &str) -> bool {
    (|| -> Option<bool> {
        let key: [u8; 32] = B64.decode(key).ok()?.try_into().ok()?;
        let sig = Signature::from_slice(&B64.decode(signature).ok()?).ok()?;
        Some(
            VerifyingKey::from_bytes(&key)
                .ok()?
                .verify_strict(message.as_bytes(), &sig)
                .is_ok(),
        )
    })()
    .unwrap_or(false)
}
fn header<'a>(headers: &'a HeaderMap, name: &str) -> &'a str {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
}
fn valid_fields(value: &Value, fields: &[&str]) -> bool {
    value
        .as_object()
        .is_some_and(|v| v.len() == fields.len() && fields.iter().all(|key| v.contains_key(*key)))
}
fn forbidden() -> Response {
    (StatusCode::FORBIDDEN, "denied").into_response()
}
async fn handle(
    State(shared): State<Shared>,
    Path((account, room_id, operation)): Path<(String, String, String)>,
    headers: HeaderMap,
    upgrade: std::result::Result<
        WebSocketUpgrade,
        axum::extract::ws::rejection::WebSocketUpgradeRejection,
    >,
    raw: Bytes,
) -> Response {
    let mut data = shared.lock().unwrap();
    let room_key = (account.clone(), room_id.clone());
    let now = SystemClock.now_ms().unwrap() + data.clock_offset;
    if raw.len() > 4096 {
        return StatusCode::PAYLOAD_TOO_LARGE.into_response();
    }
    let value: Value = serde_json::from_slice(&raw).unwrap_or(Value::Null);
    let device = value["device_id"].as_str().unwrap_or("").to_owned();
    if operation == "create" {
        if header(&headers, "authorization") != format!("Bearer {SECRET}") {
            return forbidden();
        }
        if data.rooms.contains_key(&room_key) {
            return StatusCode::CONFLICT.into_response();
        }
        if !valid_fields(&value, &["device_id", "public_key"]) {
            return forbidden();
        }
        let proof =
            json!(["voiceremote-relay-create-v1", account, room_id, hash(&raw)]).to_string();
        if !verify(
            value["public_key"].as_str().unwrap_or(""),
            header(&headers, "x-relay-signature"),
            &proof,
        ) {
            return forbidden();
        }
        let mut room = Room::default();
        room.members.insert(
            device,
            Member {
                key: value["public_key"].as_str().unwrap().into(),
            },
        );
        data.rooms.insert(room_key, room);
        return (
            StatusCode::CREATED,
            axum::Json(json!({"created":true,"server_time":now,"expires_at":now+120_000})),
        )
            .into_response();
    }
    data.serial += 1;
    let serial = data.serial;
    let bad_context = data.bad_context;
    let lifetime = if data.challenge_lifetime == 0 {
        60_000
    } else {
        data.challenge_lifetime
    };
    let Some(room) = data.rooms.get_mut(&room_key) else {
        return forbidden();
    };
    if operation == "challenge" {
        if !valid_fields(&value, &["device_id", "operation", "body_sha256"]) {
            return forbidden();
        }
        let Some(member) = room.members.get(&device) else {
            return forbidden();
        };
        let proof = json!([
            "voiceremote-relay-challenge-v1",
            account,
            room_id,
            hash(&raw)
        ])
        .to_string();
        if !verify(&member.key, header(&headers, "x-relay-signature"), &proof) {
            return forbidden();
        }
        let nonce = B64.encode(Sha256::digest(serial.to_be_bytes()));
        let expires = if lifetime < 0 {
            now.saturating_sub(lifetime.unsigned_abs())
        } else {
            now + lifetime as u64
        };
        let message = json!([
            "voiceremote-relay-auth-v1",
            account,
            room_id,
            device,
            value["operation"],
            value["body_sha256"],
            nonce,
            expires
        ])
        .to_string();
        room.challenges.insert(
            nonce.clone(),
            Challenge {
                device,
                op: value["operation"].as_str().unwrap().into(),
                digest: value["body_sha256"].as_str().unwrap().into(),
                message: message.clone(),
                expires,
            },
        );
        let message = if bad_context {
            json!(["cross-account-challenge"]).to_string()
        } else {
            message
        };
        return axum::Json(
            json!({"challenge":nonce,"message":message,"expires_at":expires,"server_time":now}),
        )
        .into_response();
    }
    if operation == "join" {
        if !valid_fields(
            &value,
            &[
                "device_id",
                "public_key",
                "one_use_token",
                "expires_at",
                "signature",
            ],
        ) {
            return forbidden();
        }
        let token = value["one_use_token"].as_str().unwrap_or("");
        let Some(invite) = room.invites.get(&hash(token.as_bytes())) else {
            return forbidden();
        };
        let message = json!([
            "voiceremote-relay-join-v1",
            account,
            room_id,
            device,
            value["public_key"],
            token,
            invite.expires
        ])
        .to_string();
        if value["expires_at"] != invite.expires
            || invite.expires <= now
            || !verify(
                value["public_key"].as_str().unwrap_or(""),
                value["signature"].as_str().unwrap_or(""),
                &message,
            )
        {
            return forbidden();
        }
        room.invites.remove(&hash(token.as_bytes()));
        if room.members.contains_key(&device) {
            return StatusCode::CONFLICT.into_response();
        }
        room.members.insert(
            device,
            Member {
                key: value["public_key"].as_str().unwrap().into(),
            },
        );
        return (StatusCode::CREATED, axum::Json(json!({"joined":true}))).into_response();
    }
    // Consume even invalid signatures, exactly as the worker does.
    let Some(challenge) = room
        .challenges
        .remove(header(&headers, "x-relay-challenge"))
    else {
        return forbidden();
    };
    let Some(member) = room.members.get(&challenge.device).cloned() else {
        return forbidden();
    };
    if challenge.op != operation
        || challenge.digest != hash(&raw)
        || challenge.expires <= now
        || !verify(
            &member.key,
            header(&headers, "x-relay-signature"),
            &challenge.message,
        )
    {
        return forbidden();
    }
    if operation == "invite" {
        if !valid_fields(&value, &["token_sha256", "expires_at"]) {
            return forbidden();
        }
        let expires = value["expires_at"].as_u64().unwrap_or(0);
        if expires <= now || expires - now > 120_000 {
            return forbidden();
        }
        room.invites.insert(
            value["token_sha256"].as_str().unwrap_or("").into(),
            Invite { expires },
        );
        return (
            StatusCode::CREATED,
            axum::Json(json!({"registered":true,"expires_at":expires})),
        )
            .into_response();
    }
    if operation == "revoke" {
        if !valid_fields(&value, &["device_id"]) || room.members.remove(&device).is_none() {
            return forbidden();
        }
        if let Some(socket) = data.sockets.remove(&(account, room_id, device)) {
            let _ = socket.send(Message::Close(None));
        }
        return axum::Json(json!({"revoked":true})).into_response();
    }
    if operation != "connect" || !raw.is_empty() {
        return forbidden();
    }
    let Ok(upgrade) = upgrade else {
        return StatusCode::UPGRADE_REQUIRED.into_response();
    };
    data.connects += 1;
    let device = challenge.device;
    drop(data);
    upgrade
        .max_message_size(16_384)
        .max_frame_size(16_384)
        .on_upgrade(move |socket| socket_loop(shared, account, room_id, device, socket))
        .into_response()
}
async fn socket_loop(
    shared: Shared,
    account: String,
    room: String,
    device: String,
    mut socket: WebSocket,
) {
    let (send, mut receive) = mpsc::unbounded_channel();
    let key = (account.clone(), room.clone(), device.clone());
    if let Some(old) = shared
        .lock()
        .unwrap()
        .sockets
        .insert(key.clone(), send.clone())
    {
        let _ = old.send(Message::Close(None));
    }
    loop {
        tokio::select! {
            frame=socket.recv()=>{
                match frame {
                    Some(Ok(Message::Text(text)))=>{
                        let decoded:RelayFrame=match decode(&text){Ok(frame)=>frame,Err(_)=>break};let mut data=shared.lock().unwrap();
                        data.frames+=1;data.max_frame=data.max_frame.max(text.len());if text.len()>16_384{break;}
                        if let RelayFrame::RelayCiphertext(frame)=decoded {
                            if frame.account_id!=account||frame.room_id!=room||frame.sender_device_id!=device{break;}
                            for ((a,r,d),target) in &data.sockets {if *a==account&&*r==room&&*d!=device{let _=target.send(Message::Text(text.clone()));}}
                        }
                    },
                    Some(Ok(Message::Ping(bytes)))=>{if socket.send(Message::Pong(bytes)).await.is_err(){break;}},
                    Some(Ok(Message::Pong(_)))=>{},
                    _=>break,
                }
            },
            frame=receive.recv()=>{let Some(frame)=frame else{break;};let close=matches!(frame,Message::Close(_));if socket.send(frame).await.is_err()||close{break;}},
        }
    }
    let mut data = shared.lock().unwrap();
    if data
        .sockets
        .get(&key)
        .is_some_and(|current| current.same_channel(&send))
    {
        data.sockets.remove(&key);
    }
}
struct Fake {
    origin: String,
    state: Shared,
    worker: JoinHandle<()>,
}
impl Drop for Fake {
    fn drop(&mut self) {
        self.worker.abort();
    }
}
impl Fake {
    async fn start() -> Result<Self> {
        let state = Shared::default();
        let app = Router::new()
            .route("/v1/accounts/{account}/rooms/{room}/{op}", any(handle))
            .with_state(state.clone());
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let origin = format!("http://{}", listener.local_addr()?);
        let worker = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Ok(Self {
            origin,
            state,
            worker,
        })
    }
    fn client(&self, id: &str, key: RelayIdentity) -> Result<RelayClient> {
        RelayClient::loopback(
            &self.origin,
            RelayRoute {
                account: "synthetic-account".into(),
                room: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
                sender: id.into(),
            },
            key,
        )
    }
}
#[derive(Default)]
struct Memory(Mutex<HashMap<String, Vec<u8>>>);
impl KeyStore for Memory {
    fn get(&self, k: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        Ok(self.0.lock().unwrap().get(k).cloned().map(Zeroizing::new))
    }
    fn put(&self, k: &str, v: &[u8]) -> Result<()> {
        self.0.lock().unwrap().insert(k.into(), v.into());
        Ok(())
    }
    fn delete(&self, k: &str) -> Result<()> {
        self.0.lock().unwrap().remove(k);
        Ok(())
    }
    fn reserve(&self, k: &str) -> Result<bool> {
        let mut data = self.0.lock().unwrap();
        if data.contains_key(k) {
            return Ok(false);
        }
        data.insert(k.into(), vec![1]);
        Ok(true)
    }
}
fn registry() -> Registry {
    Registry::new(Arc::new(Memory::default()))
}
fn info(device: &str) -> DeviceInfo {
    DeviceInfo {
        kind: DeviceInfoKind::DeviceInfo,
        account_id: "synthetic-account".into(),
        device_id: device.into(),
        display_name: device.into(),
        platform: DeviceInfoPlatform::Linux,
        role: DeviceInfoRole::TextReceiver,
        capabilities: vec![Capability::ReceiveText],
    }
}
#[derive(Default)]
struct Injector(String);
impl TextInjector for Injector {
    fn insert_text(&mut self, text: &str) -> Result<()> {
        self.0.push_str(text);
        Ok(())
    }
}

#[tokio::test]
async fn signed_first_room_invite_join_full_xx_maximum_dictation_and_revoke() -> Result<()> {
    let fake = Fake::start().await?;
    let desktop = fake.client("desktop", RelayIdentity::generate())?;
    let phone_key = RelayIdentity::generate();
    let phone = fake.client("phone", phone_key.clone())?;
    assert!(
        desktop
            .bootstrap("incorrect-provisioning-secret-32-bytes")
            .await
            .is_err()
    );
    desktop.bootstrap(SECRET).await?;
    assert!(desktop.bootstrap(SECRET).await.is_err());
    let invitation = desktop.invite().await?;
    let di = Identity::generate()?;
    let pi = Identity::generate()?;
    let mut offer = Offer::from_relay_invite(
        &di,
        "synthetic-account".into(),
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
        invitation.one_use_token.clone(),
        invitation.expires_at,
        &SystemClock,
    )?;
    assert_eq!(offer.payload.one_use_token, invitation.one_use_token);
    phone.join(&invitation).await?;
    assert!(phone.join(&invitation).await.is_err());
    let mut dt = RelayTransport::connect(&desktop).await?;
    let mut pt = RelayTransport::connect(&phone).await?;
    let payload = offer.payload.clone();
    let (pp, dp) = tokio::join!(
        pairing::initiate(&mut pt, &pi, &payload, &SystemClock),
        pairing::accept(&mut dt, &di, &mut offer, &SystemClock)
    );
    let mut pp = pp?;
    let mut dp = dp?;
    let phrase = pp.phrase();
    assert_eq!(phrase, dp.phrase());
    pp.confirm_local(&mut pt, &phrase, info("phone")).await?;
    dp.confirm_local(&mut dt, &phrase, info("desktop")).await?;
    pp.receive_confirmation(&mut pt).await?;
    dp.receive_confirmation(&mut dt).await?;
    let dr = registry();
    let mut ps = pp.finish(registry())?;
    let mut ds = dp.finish(dr.clone())?;
    let text = "🦀".repeat(16_384);
    let message = InnerMessage::DictationText(DictationText {
        preparation_id: None,
        kind: DictationTextKind::DictationText,
        account_id: "synthetic-account".into(),
        segment_id: "synthetic-segment".into(),
        revision: 1,
        state: DictationTextState::Committed,
        target_device_id: "desktop".into(),
        text: text.clone(),
    });
    ps.send(&mut pt, &message).await?;
    let received = ds.receive(&mut dt).await?;
    let mut injector = Injector::default();
    ds.deliver(&mut dt, received, &mut injector).await?;
    assert_eq!(injector.0, text);
    assert!(fake.state.lock().unwrap().max_frame <= 16_384);
    assert!(fake.state.lock().unwrap().frames > 10);
    assert!(matches!(
        ps.receive(&mut pt).await?,
        InnerMessage::DictationOutcome(DictationOutcome {
            outcome: DictationOutcomeOutcome::Inserted,
            ..
        })
    ));
    desktop.revoke("phone").await?;
    assert!(
        tokio::time::timeout(Duration::from_secs(1), pt.recv())
            .await?
            .is_err()
    );
    dr.revoke(&ds.peer().id)?;
    assert!(ds.receive(&mut dt).await.is_err());
    Ok(())
}
#[tokio::test]
async fn relay_requires_key_proof_rejects_challenge_context_and_consumes_replay() -> Result<()> {
    let fake = Fake::start().await?;
    let desktop = fake.client("desktop", RelayIdentity::generate())?;
    desktop.bootstrap(SECRET).await?;
    let impostor = fake.client("desktop", RelayIdentity::generate())?;
    assert!(RelayTransport::connect(&impostor).await.is_err());
    fake.state.lock().unwrap().bad_context = true;
    assert!(desktop.connect_request().await.is_err());
    fake.state.lock().unwrap().bad_context = false;
    for lifetime in [-1, 600_000] {
        fake.state.lock().unwrap().challenge_lifetime = lifetime;
        assert!(desktop.connect_request().await.is_err());
    }
    fake.state.lock().unwrap().challenge_lifetime = 0;
    let request = desktop.connect_request().await?;
    let replay = request.clone();
    let (mut socket, _) = tokio_tungstenite::connect_async(request).await?;
    assert!(tokio_tungstenite::connect_async(replay).await.is_err());
    socket.close(None).await?;
    Ok(())
}
#[tokio::test]
async fn relay_receiver_reconnects_after_disconnect_and_stops_during_wait() -> Result<()> {
    let fake = Fake::start().await?;
    let desktop = fake.client("desktop", RelayIdentity::generate())?;
    desktop.bootstrap(SECRET).await?;
    let registry = registry();
    let peer = registry.enroll(
        Identity::generate()?.public,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
        info("phone"),
    )?;
    let (stop, watch) = tokio::sync::watch::channel(false);
    let factory: voiceremote_core::receiver::InjectorFactory =
        Arc::new(|| Box::new(Injector::default()));
    let runner = tokio::spawn(voiceremote_core::receiver::run_relay(
        desktop,
        Arc::new(Identity::generate()?),
        registry,
        peer,
        "desktop".into(),
        factory,
        watch,
    ));
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if fake.state.lock().unwrap().connects >= 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        for socket in fake.state.lock().unwrap().sockets.values() {
            let _ = socket.send(Message::Close(None));
        }
        loop {
            if fake.state.lock().unwrap().connects >= 2 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await?;
    stop.send(true)?;
    tokio::time::timeout(Duration::from_secs(1), runner).await???;
    Ok(())
}

#[tokio::test]
async fn member_challenge_uses_server_clock_when_desktop_is_behind() -> Result<()> {
    let fake = Fake::start().await?;
    let desktop = fake.client("desktop", RelayIdentity::generate())?;
    desktop.bootstrap(SECRET).await?;
    fake.state.lock().unwrap().clock_offset = 3_600_000;
    assert!(desktop.connect_request().await.is_ok());
    Ok(())
}
