//! Trusted UI adapter around core pairing/registry and the shared desktop driver.
use crate::{
    control, desktop_receiver as receiver,
    desktop_transport::{LanListener, RelayTransport},
    model::{QrView, RotatingOffer},
};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{oneshot, watch};
use voiceremote_core::{
    pairing::{self, Clock, Offer, SystemClock},
    protocol::*,
    relay::{RelayClient, RelayIdentity},
    storage::{Identity, KeyStore, ReceiverLease, Registry},
    transport::{RelayRoute, Transport},
};

#[derive(Clone, Serialize, Deserialize)]
pub struct Settings {
    pub account: String,
    pub device: String,
    pub relay: Option<String>,
    pub role: DeviceInfoRole,
}
impl Settings {
    fn info(&self) -> Result<DeviceInfo> {
        let mut info = crate::info(&self.account, &self.device);
        info.role = self.role.clone();
        if self.role == DeviceInfoRole::Agent {
            info.capabilities.clear();
        }
        encode(&info).map_err(anyhow::Error::msg)?;
        Ok(info)
    }
}
#[derive(Clone, Serialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub role: DeviceInfoRole,
}
#[derive(Clone, Default, Serialize)]
pub struct View {
    pub qr: Option<QrView>,
    pub phrase: Option<String>,
    pub pairing: bool,
    pub message: String,
}
#[derive(Serialize)]
pub struct Snapshot {
    pub view: View,
    pub status: control::Status,
    pub devices: Vec<Device>,
    pub settings: Option<Settings>,
}
struct Worker {
    stop: watch::Sender<bool>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
        self.task.abort();
    }
}
pub struct Backend {
    pub root: PathBuf,
    keys: Arc<dyn KeyStore>,
    registry: Registry,
    identity: Arc<Identity>,
    _lease: ReceiverLease,
    settings: Mutex<Option<Settings>>,
    view: Mutex<View>,
    confirmation: Mutex<Option<oneshot::Sender<String>>>,
    workers: Mutex<Vec<Worker>>,
    injectors: receiver::InjectorFactory,
}
impl Backend {
    pub fn open(root: PathBuf) -> Result<Arc<Self>> {
        let lease = ReceiverLease::acquire(&root)?;
        #[cfg(all(windows, feature = "os-keychain"))]
        let keys: Arc<dyn KeyStore> = Arc::new(voiceremote_core::storage::OsKeyStore {
            service: "voiceremote-desktop".into(),
        });
        #[cfg(not(all(windows, feature = "os-keychain")))]
        let keys: Arc<dyn KeyStore> =
            Arc::new(voiceremote_core::storage::FileKeyStore::new(&root)?);
        let registry = Registry::new(keys.clone());
        let identity = Arc::new(Identity::load_or_create(keys.as_ref())?);
        let settings = keys
            .get("tray-settings")?
            .map(|s| serde_json::from_slice(&s))
            .transpose()?;
        let injectors = injectors(&root);
        Ok(Arc::new(Self {
            root,
            keys,
            registry,
            identity,
            _lease: lease,
            settings: Mutex::new(settings),
            view: Mutex::new(View::default()),
            confirmation: Mutex::new(None),
            workers: Mutex::new(Vec::new()),
            injectors,
        }))
    }
    pub fn snapshot(&self) -> Result<Snapshot> {
        Ok(Snapshot {
            view: self.view.lock().unwrap().clone(),
            status: control::hub().lock().unwrap().snapshot(),
            settings: self.settings.lock().unwrap().clone(),
            devices: self
                .registry
                .devices()?
                .into_iter()
                .map(|p| Device {
                    id: p.id,
                    name: p.info.display_name,
                    role: p.info.role,
                })
                .collect(),
        })
    }
    fn client(&self, settings: &Settings, room: String) -> Result<RelayClient> {
        RelayClient::new(
            settings
                .relay
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("relay missing"))?,
            RelayRoute {
                account: settings.account.clone(),
                room,
                sender: settings.device.clone(),
            },
            RelayIdentity::load_or_create(self.keys.as_ref())?,
        )
    }
    fn message(&self, message: &str) {
        self.view.lock().unwrap().message = message.into();
    }
    pub fn start(self: &Arc<Self>) {
        let backend = self.clone();
        tokio::spawn(async move {
            if control::serve(&backend.root, control::hub().clone())
                .await
                .is_err()
            {
                backend.message("Local hotkey control unavailable");
            }
        });
        self.resume();
    }
    fn resume(self: &Arc<Self>) {
        self.resume_except(None);
    }
    fn resume_except(self: &Arc<Self>, exclude: Option<&str>) {
        let Some(settings) = self.settings.lock().unwrap().clone() else {
            return;
        };
        let Ok(peers) = self.registry.devices() else {
            self.message("Cannot load paired devices");
            return;
        };
        for peer in peers
            .into_iter()
            .filter(|p| p.info.account_id == settings.account && exclude != Some(p.id.as_str()))
        {
            let backend = self.clone();
            let settings = settings.clone();
            let (send, stop) = watch::channel(false);
            let task = tokio::spawn(async move {
                let result: Result<()> = async {
                    if settings.relay.is_some() {
                        receiver::run_relay(
                            backend.client(&settings, peer.room.clone())?,
                            backend.identity.clone(),
                            backend.registry.clone(),
                            peer,
                            settings.device,
                            backend.injectors.clone(),
                            stop,
                        )
                        .await
                    } else {
                        let mut listener = LanListener::bind_auto().await?;
                        listener.advertise(&peer.room)?;
                        receiver::run_lan(
                            listener,
                            backend.identity.clone(),
                            backend.registry.clone(),
                            peer,
                            settings.device,
                            backend.injectors.clone(),
                            stop,
                            None,
                        )
                        .await
                    }
                }
                .await;
                if result.is_err() {
                    backend
                        .message("Receiver unavailable; check network and restart Voice Receiver");
                }
            });
            self.workers
                .lock()
                .unwrap()
                .push(Worker { stop: send, task });
        }
    }
    pub fn pair(self: &Arc<Self>, mut settings: Settings) -> Result<()> {
        settings.relay = settings.relay.filter(|s| !s.trim().is_empty());
        settings.info()?;
        if let Some(local) = self.registry.local_info()? {
            ensure!(
                local.device_id == settings.device && local.account_id == settings.account,
                "existing desktop identity must be retained"
            );
        }
        {
            let mut view = self.view.lock().unwrap();
            ensure!(!view.pairing, "pairing already active");
            *view = View {
                pairing: true,
                message: "Preparing pairing…".into(),
                ..View::default()
            };
        }
        self.workers.lock().unwrap().clear();
        let backend = self.clone();
        let (send, stop) = watch::channel(false);
        let task = tokio::spawn(async move {
            let result = backend.pair_loop(settings, stop).await;
            backend.confirmation.lock().unwrap().take();
            *backend.view.lock().unwrap() = View {
                message: if result.is_ok() {
                    "Phone paired"
                } else {
                    "Pairing ended; compare both phrases and try again"
                }
                .into(),
                ..View::default()
            };
            if result.is_err() {
                backend.resume();
            }
        });
        self.workers
            .lock()
            .unwrap()
            .push(Worker { stop: send, task });
        Ok(())
    }
    async fn pair_loop(
        self: &Arc<Self>,
        settings: Settings,
        stop: watch::Receiver<bool>,
    ) -> Result<()> {
        let client = if settings.relay.is_some() {
            let client = self.client(&settings, voiceremote_core::relay::new_room_id())?;
            client.create(None).await?;
            Some(client)
        } else {
            None
        };
        let room = client
            .as_ref()
            .map(|c| c.route.room.clone())
            .unwrap_or_else(voiceremote_core::relay::new_room_id);
        let listener = if client.is_none() {
            let mut listener = LanListener::bind_auto().await?;
            listener.advertise(&room)?;
            Some(listener)
        } else {
            None
        };
        loop {
            let mut qr = if let Some(client) = &client {
                let invite = client.invite().await?;
                RotatingOffer::from_offer(Offer::from_relay_invite(
                    &self.identity,
                    settings.account.clone(),
                    room.clone(),
                    invite.one_use_token,
                    invite.expires_at,
                    &SystemClock,
                )?)?
            } else {
                RotatingOffer::new(
                    &self.identity,
                    settings.account.clone(),
                    room.clone(),
                    &SystemClock,
                )?
            };
            {
                let mut view = self.view.lock().unwrap();
                view.qr = Some(qr.view());
                view.phrase = None;
                view.message = "Scan on your phone, then compare the four words".into();
            }
            let deadline = Duration::from_millis(
                qr.offer
                    .payload
                    .expires_at
                    .saturating_sub(SystemClock.now_ms()?),
            );
            let accepted: Result<(pairing::PendingPair, Box<dyn Transport>)> = tokio::select! {
                _=receiver::stopped(stop.clone())=>anyhow::bail!("pairing cancelled"),
                result=tokio::time::timeout(deadline, async {
                    let mut transport: Box<dyn Transport> = if let Some(client) = &client { Box::new(RelayTransport::connect(client).await?) } else { Box::new(listener.as_ref().unwrap().accept().await?) };
                    let pending = pairing::accept(transport.as_mut(), &self.identity, &mut qr.offer, &SystemClock).await?;
                    Ok((pending, transport))
                })=>match result { Ok(result)=>result, Err(_)=>continue },
            };
            let Ok((mut pending, mut transport)) = accepted else {
                continue;
            };
            // Token is consumed. Remove QR immediately; never reuse it after abort.
            let (send, receive) = oneshot::channel();
            *self.confirmation.lock().unwrap() = Some(send);
            {
                let mut view = self.view.lock().unwrap();
                view.qr = None;
                view.phrase = Some(pending.phrase());
                view.message =
                    "Compare on both displays. Enter all four words to confirm here.".into();
            }
            let completion: Result<_> = tokio::select! {
                _=receiver::stopped(stop.clone())=>anyhow::bail!("pairing cancelled"),
                result=tokio::time::timeout(Duration::from_secs(120), async {
                    let entered = receive.await?;
                    pending.confirm_local(transport.as_mut(), &entered, settings.info()?).await?;
                    pending.receive_confirmation(transport.as_mut()).await?;
                    let session = pending.finish(self.registry.clone())?;
                    self.keys.put("tray-settings", &serde_json::to_vec(&settings)?)?;
                    *self.settings.lock().unwrap() = Some(settings.clone());
                    Ok(session)
                })=>result?,
            };
            let session = completion?;
            *self.view.lock().unwrap() = View {
                message: "Phone paired; waiting for phone state".into(),
                ..View::default()
            };
            // Keep the freshly enrolled session instead of requiring a reconnect.
            let backend = self.clone();
            let (send, session_stop) = watch::channel(false);
            let peer = session.peer().clone();
            let paired_id = peer.id.clone();
            let task = tokio::spawn(async move {
                if let Some(listener) = listener {
                    let _ = receiver::run_lan(
                        listener,
                        backend.identity.clone(),
                        backend.registry.clone(),
                        peer,
                        settings.device,
                        backend.injectors.clone(),
                        session_stop,
                        Some((session, transport)),
                    )
                    .await;
                } else {
                    let _ = receiver::serve(
                        session,
                        transport.as_mut(),
                        (backend.injectors)().as_mut(),
                        session_stop.clone(),
                    )
                    .await;
                    let _ = receiver::run_relay(
                        client.unwrap(),
                        backend.identity.clone(),
                        backend.registry.clone(),
                        peer,
                        settings.device,
                        backend.injectors.clone(),
                        session_stop,
                    )
                    .await;
                }
            });
            self.workers
                .lock()
                .unwrap()
                .push(Worker { stop: send, task });
            self.resume_except(Some(&paired_id));
            return Ok(());
        }
    }
    pub fn confirm(&self, phrase: String) -> Result<()> {
        let send = self
            .confirmation
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| anyhow::anyhow!("no confirmation pending"))?;
        send.send(phrase)
            .map_err(|_| anyhow::anyhow!("pairing expired"))?;
        let mut view = self.view.lock().unwrap();
        view.phrase = None;
        view.message = "Waiting for confirmation on your phone".into();
        Ok(())
    }
    pub fn cancel(self: &Arc<Self>) {
        self.workers.lock().unwrap().clear();
        self.confirmation.lock().unwrap().take();
        *self.view.lock().unwrap() = View {
            message: "Pairing cancelled".into(),
            ..View::default()
        };
        self.resume();
    }
    pub async fn revoke(&self, id: &str) -> Result<()> {
        let peer = self.registry.resolve(id)?;
        self.registry.revoke(&peer.id)?;
        let settings = self.settings.lock().unwrap().clone();
        if let Some(settings) = settings.filter(|s| s.relay.is_some()) {
            if self
                .client(&settings, peer.room)?
                .revoke(&peer.info.device_id)
                .await
                .is_err()
            {
                self.message("Revoked locally; relay room cleanup failed");
                anyhow::bail!("revoked locally; relay cleanup failed");
            }
        }
        self.message("Device revoked");
        Ok(())
    }
}
fn injectors(root: &Path) -> receiver::InjectorFactory {
    #[cfg(target_os = "linux")]
    {
        let injector = voiceremote_inject_linux::LinuxInjector::new(root.to_owned());
        let sampler = injector.clone();
        receiver::set_focus_sampler(Arc::new(move || {
            let focus = sampler.focus_snapshot();
            (focus.text_field_focused, focus.last_activity_at)
        }));
        Arc::new(move || Box::new(injector.clone()))
    }
    #[cfg(windows)]
    {
        let _ = root;
        receiver::set_focus_sampler(Arc::new(|| {
            let focus = voiceremote_inject_windows::focus_snapshot();
            (focus.text_field_focused, focus.last_activity_at)
        }));
        Arc::new(|| {
            Box::new(voiceremote_inject_windows::WindowsInjector)
                as Box<dyn voiceremote_core::TextInjector>
        })
    }
}
/// Deliberately accepts only a fixed enum; no content or error strings enter logs.
pub enum LogEvent {
    Started,
    PairRequested,
    Confirmed,
    Revoked,
    AutostartChanged,
    Stopped,
}
pub fn log(root: &Path, event: LogEvent) -> Result<()> {
    use std::io::Write;
    let name = match event {
        LogEvent::Started => "started",
        LogEvent::PairRequested => "pair-requested",
        LogEvent::Confirmed => "confirmed",
        LogEvent::Revoked => "revoked",
        LogEvent::AutostartChanged => "autostart-changed",
        LogEvent::Stopped => "stopped",
    };
    let path = root.join("tray.log");
    if let Ok(meta) = std::fs::symlink_metadata(&path) {
        ensure!(
            meta.is_file() && !meta.file_type().is_symlink(),
            "unsafe log path"
        );
        if meta.len() > 64 * 1024 {
            std::fs::remove_file(&path)?;
        }
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    writeln!(options.open(path)?, "{} {name}", SystemClock.now_ms()?)?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[tokio::test]
    async fn persisted_devices_reopen_and_revoke_through_the_core_registry() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let state = dir.path().join("state");
        let backend = Backend::open(state.clone())?;
        assert!(
            Backend::open(state.clone()).is_err(),
            "one receiver per state directory"
        );
        let settings = Settings {
            account: "synthetic-account".into(),
            device: "desktop".into(),
            relay: None,
            role: DeviceInfoRole::TextReceiver,
        };
        backend.registry.remember_local(&settings.info()?)?;
        backend
            .keys
            .put("tray-settings", &serde_json::to_vec(&settings)?)?;
        let peer = backend.registry.enroll(
            Identity::generate()?.public,
            "synthetic-room".into(),
            crate::info("synthetic-account", "phone"),
        )?;
        assert!(backend.confirm("unrequested phrase".into()).is_err());
        assert_eq!(backend.snapshot()?.devices.len(), 1);
        drop(backend);
        let reopened = Backend::open(state)?;
        assert_eq!(reopened.snapshot()?.settings.unwrap().device, "desktop");
        reopened.revoke(&peer.id).await?;
        assert!(reopened.snapshot()?.devices.is_empty());
        assert!(reopened.registry.require(&peer).is_err());
        Ok(())
    }
    #[test]
    fn log_contains_fixed_events_only() -> Result<()> {
        let dir = tempfile::tempdir()?;
        log(dir.path(), LogEvent::PairRequested)?;
        let text = std::fs::read_to_string(dir.path().join("tray.log"))?;
        assert!(text.lines().all(|line| {
            line.split_once(' ').is_some_and(|(time, event)| {
                time.parse::<u64>().is_ok() && event == "pair-requested"
            })
        }));
        Ok(())
    }
    #[test]
    fn role_never_adds_execution_capabilities() -> Result<()> {
        for role in [
            DeviceInfoRole::TextReceiver,
            DeviceInfoRole::Agent,
            DeviceInfoRole::Both,
        ] {
            let info = Settings {
                account: "test".into(),
                device: "desktop".into(),
                relay: None,
                role,
            }
            .info()?;
            assert!(
                info.capabilities
                    .iter()
                    .all(|c| *c == Capability::ReceiveText)
            );
        }
        Ok(())
    }
}
