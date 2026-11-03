//! RemoteDesktop permission, libei text, and native portal clipboard transport.
//! Permission persistence and guarded restoration follow Hex/Handy designs.
// Copyright (c) 2026 Christopher Langton
// Copyright (c) 2025 CJ Pais
// MIT adaptations; see DOCS/licences/{hex,handy}-MIT.txt.
use anyhow::{Result, bail, ensure};
use ashpd::desktop::{
    PersistMode, Session,
    clipboard::{Clipboard, SetSelectionOptions},
    remote_desktop::{DeviceType, KeyState, RemoteDesktop, SelectDevicesOptions},
};
use futures_util::{FutureExt, StreamExt};
use reis::{PendingRequestResult, ei};
use std::{
    collections::{BTreeMap, HashMap},
    os::fd::{AsRawFd, OwnedFd},
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{io::unix::AsyncFd, time::timeout};
use voiceremote_core::storage::{FileKeyStore, KeyStore};
const IO_TIME: Duration = Duration::from_secs(2);
const CAP: usize = 32 * 1024 * 1024;
const TOKEN: &str = "remote-desktop-restore-token";

pub(crate) struct Portal {
    remote: RemoteDesktop,
    session: Session<RemoteDesktop>,
    clipboard: Option<PortalClipboard>,
    eis: Option<EisClient>,
    eis_attempted: bool,
    eis_established: bool,
}
impl Portal {
    pub(crate) async fn open(path: &Path) -> Result<Self> {
        Self::open_with_connection(path, zbus::Connection::session().await?).await
    }
    async fn open_with_connection(path: &Path, connection: zbus::Connection) -> Result<Self> {
        let store = FileKeyStore::new(path.join("linux-input"))?;
        let token = store.get(TOKEN)?;
        let token = token.as_deref().and_then(|v| std::str::from_utf8(v).ok());
        let remote = RemoteDesktop::with_connection(connection.clone()).await?;
        let session = remote.create_session(Default::default()).await?;
        remote
            .select_devices(
                &session,
                SelectDevicesOptions::default()
                    .set_devices(enumflags2::BitFlags::from(DeviceType::Keyboard))
                    .set_persist_mode(PersistMode::ExplicitlyRevoked)
                    .set_restore_token(token),
            )
            .await?
            .response()?;
        let clipboard = PortalClipboard::open(connection, &session).await.ok();
        let response = match remote
            .start(&session, None, Default::default())
            .await
            .and_then(|r| r.response())
        {
            Ok(response) => response,
            Err(_) => {
                store.delete(TOKEN)?;
                bail!("portal permission unavailable");
            }
        };
        ensure!(
            response.devices().contains(DeviceType::Keyboard),
            "portal keyboard access denied"
        );
        if let Some(token) = response.restore_token() {
            store.put(TOKEN, token.as_bytes())?;
        } else {
            store.delete(TOKEN)?;
        }
        let clipboard = clipboard.filter(|_| response.is_clipboard_enabled());
        // Approval dialogs can temporarily hold focus. Re-query focus afterwards.
        tokio::time::sleep(Duration::from_millis(250)).await;
        Ok(Self {
            remote,
            session,
            clipboard,
            eis: None,
            eis_attempted: false,
            eis_established: false,
        })
    }
    pub(crate) async fn eis(&mut self) -> Result<&mut EisClient> {
        if !self.eis_attempted {
            self.eis_attempted = true;
            ensure!(
                std::env::var_os("REIS_DEBUG").is_none(),
                "EIS wire debugging disabled for privacy"
            );
            let fd = self
                .remote
                .connect_to_eis(&self.session, Default::default())
                .await?;
            self.eis_established = true; // irreversible, even if the handshake fails
            self.eis = Some(EisClient::start(Eis::open(fd.into()).await?));
        }
        self.eis
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("EIS unavailable"))
    }
    pub(crate) fn can_paste(&self, terminal: bool) -> bool {
        if self.eis_established {
            self.eis.as_ref().is_some_and(|eis| eis.can_paste(terminal))
        } else {
            true
        }
    }
    pub(crate) async fn paste(&mut self, terminal: bool) -> Result<()> {
        if self.eis_established {
            return self
                .eis
                .as_mut()
                .ok_or_else(|| anyhow::anyhow!("EIS unavailable"))?
                .paste(terminal)
                .await;
        }
        let mut symbols = vec![0xffe3];
        if terminal {
            symbols.push(0xffe1);
        }
        symbols.push(b'v' as i32);
        let mut result = Ok(());
        for &sym in &symbols {
            if let Err(error) = self.key(sym, KeyState::Pressed).await {
                result = Err(error);
                break;
            }
        }
        for &sym in symbols.iter().rev() {
            let released = self.key(sym, KeyState::Released).await;
            if result.is_ok() {
                result = released;
            }
        }
        result
    }
    async fn key(&self, sym: i32, state: KeyState) -> Result<()> {
        ensure!(
            matches!(sym, 0xffe3 | 0xffe1 | 0x76),
            "forbidden portal key"
        );
        timeout(
            IO_TIME,
            self.remote
                .notify_keyboard_keysym(&self.session, sym, state, Default::default()),
        )
        .await??;
        Ok(())
    }
    pub(crate) async fn prepare_clipboard(&self) -> Result<BTreeMap<String, Vec<u8>>> {
        self.clipboard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("clipboard portal unavailable"))?
            .snapshot(&self.session)
            .await
    }
    pub(crate) async fn install_clipboard(
        &self,
        text: &str,
        saved: BTreeMap<String, Vec<u8>>,
    ) -> Result<u64> {
        self.clipboard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("clipboard portal unavailable"))?
            .install(&self.session, text, saved)
            .await
    }
    pub(crate) async fn finish_clipboard(&self, id: u64, sent: bool) -> Result<bool> {
        self.clipboard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("clipboard portal unavailable"))?
            .finish(&self.session, id, sent)
            .await
    }
}

enum EisRequest {
    Text(String, tokio::sync::oneshot::Sender<Result<()>>),
    Paste(bool, tokio::sync::oneshot::Sender<Result<()>>),
}
#[derive(Default)]
struct EisStatus {
    text: bool,
    paste: bool,
    terminal_paste: bool,
}
pub(crate) struct EisClient {
    send: tokio::sync::mpsc::Sender<EisRequest>,
    status: Arc<Mutex<EisStatus>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for EisClient {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl EisClient {
    fn start(mut eis: Eis) -> Self {
        let (send, mut receive) = tokio::sync::mpsc::channel(1);
        let status = Arc::new(Mutex::new(EisStatus::default()));
        let state = status.clone();
        let publish = |eis: &Eis, state: &Mutex<EisStatus>| {
            *state.lock().unwrap() = EisStatus {
                text: eis.supports_text(),
                paste: eis.paste_keys(false).is_some(),
                terminal_paste: eis.paste_keys(true).is_some(),
            };
        };
        publish(&eis, &status);
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    request = receive.recv() => match request {
                        Some(EisRequest::Text(text, reply)) => { let result = eis.send(&text).await; let _ = reply.send(result); }
                        Some(EisRequest::Paste(terminal, reply)) => { let result = eis.paste(terminal).await; let _ = reply.send(result); }
                        None => break,
                    },
                    event = next(&mut eis.events) => {
                        if event.and_then(|e| eis.event(e)).is_err() { break; }
                    },
                }
                publish(&eis, &state);
            }
            *state.lock().unwrap() = EisStatus::default();
        });
        Self { send, status, task }
    }
    pub(crate) fn supports_text(&self) -> bool {
        self.status.lock().unwrap().text
    }
    fn can_paste(&self, terminal: bool) -> bool {
        let s = self.status.lock().unwrap();
        if terminal { s.terminal_paste } else { s.paste }
    }
    pub(crate) fn refresh(&mut self) -> Result<()> {
        ensure!(!self.task.is_finished(), "EIS connection closed");
        Ok(())
    }
    pub(crate) async fn send(&mut self, text: &str) -> Result<()> {
        let (send, receive) = tokio::sync::oneshot::channel();
        self.send
            .send(EisRequest::Text(text.into(), send))
            .await
            .map_err(|_| anyhow::anyhow!("EIS closed"))?;
        receive
            .await
            .map_err(|_| anyhow::anyhow!("EIS input interrupted"))?
    }
    async fn paste(&mut self, terminal: bool) -> Result<()> {
        let (send, receive) = tokio::sync::oneshot::channel();
        self.send
            .send(EisRequest::Paste(terminal, send))
            .await
            .map_err(|_| anyhow::anyhow!("EIS closed"))?;
        receive
            .await
            .map_err(|_| anyhow::anyhow!("EIS input interrupted"))?
    }
}

struct Device {
    device: ei::Device,
    keyboard: Option<ei::Keyboard>,
    text: Option<ei::Text>,
    keymap: Option<crate::keymap::Keymap>,
    serial: Option<u32>,
    group: u32,
    blocked: bool,
}
pub(crate) struct Eis {
    context: ei::Context,
    events: reis::tokio::EiEventStream,
    connection: ei::Connection,
    devices: HashMap<ei::Device, Device>,
    sequence: u32,
}
impl Eis {
    async fn open(fd: OwnedFd) -> Result<Self> {
        let context = ei::Context::new(std::os::unix::net::UnixStream::from(fd))?;
        let mut events = reis::tokio::EiEventStream::new(context.clone())?;
        let response = reis::tokio::ei_handshake(
            &mut events,
            "voiceremote",
            ei::handshake::ContextType::Sender,
        )
        .await?;
        let mut this = Self {
            context,
            events,
            connection: response.connection,
            devices: HashMap::new(),
            sequence: 0,
        };
        let mut masks = HashMap::new();
        loop {
            let event = next(&mut this.events).await?;
            match event {
                ei::Event::Seat(seat, ei::seat::Event::Capability { mask, interface })
                    if matches!(interface.as_str(), "ei_text" | "ei_keyboard") =>
                {
                    *masks.entry(seat).or_insert(0) |= mask;
                }
                ei::Event::Seat(seat, ei::seat::Event::Done) => {
                    if let Some(mask) = masks.get(&seat) {
                        seat.bind(*mask);
                    }
                }
                event => this.event(event)?,
            }
            this.context.flush()?;
            if this.devices.values().any(|d| {
                d.serial.is_some()
                    && (d.text.is_some() || (d.keyboard.is_some() && d.keymap.is_some()))
            }) {
                return Ok(this);
            }
        }
    }
    fn event(&mut self, event: ei::Event) -> Result<()> {
        match event {
            ei::Event::Device(device, ei::device::Event::Interface { object }) => {
                let d = self.devices.entry(device.clone()).or_insert(Device {
                    device,
                    keyboard: None,
                    text: None,
                    keymap: None,
                    serial: None,
                    group: 0,
                    blocked: false,
                });
                if let Some(k) = object.clone().downcast::<ei::Keyboard>() {
                    d.keyboard = Some(k);
                }
                if let Some(t) = object.downcast::<ei::Text>() {
                    d.text = Some(t);
                }
            }
            ei::Event::Keyboard(
                keyboard,
                ei::keyboard::Event::Keymap {
                    keymap_type,
                    size,
                    keymap,
                },
            ) => {
                ensure!(
                    keymap_type == ei::keyboard::KeymapType::Xkb && size <= 1024 * 1024,
                    "unsupported EIS keymap"
                );
                use std::os::unix::fs::FileExt;
                let mut bytes = vec![0; size as usize];
                std::fs::File::from(keymap).read_exact_at(&mut bytes, 0)?;
                if let Some(d) = self
                    .devices
                    .values_mut()
                    .find(|d| d.keyboard.as_ref() == Some(&keyboard))
                {
                    d.keymap = crate::keymap::Keymap::parse(&bytes).ok();
                }
            }
            ei::Event::Keyboard(
                keyboard,
                ei::keyboard::Event::Modifiers {
                    group,
                    serial,
                    depressed,
                    latched,
                    ..
                },
            ) => {
                if let Some(d) = self
                    .devices
                    .values_mut()
                    .find(|d| d.keyboard.as_ref() == Some(&keyboard))
                {
                    d.group = group;
                    d.blocked = depressed | latched != 0;
                    if d.serial.is_some() {
                        d.serial = Some(serial);
                    }
                }
            }
            ei::Event::Device(device, ei::device::Event::Resumed { serial }) => {
                if let Some(d) = self.devices.get_mut(&device) {
                    d.serial = Some(serial);
                }
            }
            ei::Event::Device(device, ei::device::Event::Paused { .. }) => {
                if let Some(d) = self.devices.get_mut(&device) {
                    d.serial = None;
                }
            }
            ei::Event::Device(device, ei::device::Event::Destroyed { .. }) => {
                self.devices.remove(&device);
            }
            ei::Event::Connection(_, ei::connection::Event::Ping { ping }) => {
                ping.done(0);
                self.context.flush()?;
            }
            ei::Event::Connection(_, ei::connection::Event::Disconnected { .. }) => {
                bail!("EIS disconnected")
            }
            _ => {}
        }
        Ok(())
    }
    pub(crate) fn refresh(&mut self) -> Result<()> {
        while let Some(event) = self.events.next().now_or_never() {
            match event.ok_or_else(|| anyhow::anyhow!("EIS closed"))?? {
                PendingRequestResult::Request(event) => self.event(event)?,
                _ => bail!("invalid EIS protocol message"),
            }
        }
        self.context.flush()?;
        Ok(())
    }
    pub(crate) fn supports_text(&self) -> bool {
        self.devices
            .values()
            .any(|d| d.serial.is_some() && d.text.is_some())
    }
    fn paste_keys(&self, terminal: bool) -> Option<(ei::Device, ei::Keyboard, u32, Vec<u32>)> {
        self.devices.values().filter(|d| !d.blocked).find_map(|d| {
            Some((
                d.device.clone(),
                d.keyboard.clone()?,
                d.serial?,
                d.keymap.as_ref()?.paste(terminal, d.group)?,
            ))
        })
    }
    pub(crate) async fn send(&mut self, text: &str) -> Result<()> {
        crate::validate_text(text)?;
        self.refresh()?;
        let d = self
            .devices
            .values()
            .find(|d| d.serial.is_some() && d.text.is_some())
            .ok_or_else(|| anyhow::anyhow!("EIS text unavailable"))?;
        let (device, interface, serial) =
            (d.device.clone(), d.text.clone().unwrap(), d.serial.unwrap());
        self.sequence = self.sequence.wrapping_add(1);
        device.start_emulating(self.sequence, serial);
        for chunk in text_chunks(text) {
            interface.utf8(chunk);
            device.frame(serial, monotonic_micros());
        }
        device.stop_emulating(serial);
        self.sync().await
    }
    async fn paste(&mut self, terminal: bool) -> Result<()> {
        self.refresh()?;
        let (device, keyboard, serial, keys) = self
            .paste_keys(terminal)
            .ok_or_else(|| anyhow::anyhow!("EIS keyboard layout unavailable"))?;
        self.sequence = self.sequence.wrapping_add(1);
        device.start_emulating(self.sequence, serial);
        for &key in &keys {
            keyboard.key(key, ei::keyboard::KeyState::Press);
            device.frame(serial, monotonic_micros());
        }
        for &key in keys.iter().rev() {
            keyboard.key(key, ei::keyboard::KeyState::Released);
            device.frame(serial, monotonic_micros());
        }
        device.stop_emulating(serial);
        self.sync().await
    }
    async fn sync(&mut self) -> Result<()> {
        let callback = self.connection.sync(1);
        self.context.flush()?;
        loop {
            let event = next(&mut self.events).await?;
            match event {
                ei::Event::Callback(c, ei::callback::Event::Done { .. }) if c == callback => {
                    return Ok(());
                }
                event => self.event(event)?,
            }
        }
    }
}
fn text_chunks(mut text: &str) -> impl Iterator<Item = &str> {
    std::iter::from_fn(move || {
        if text.is_empty() {
            return None;
        }
        let mut end = text.len().min(254);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let (chunk, rest) = text.split_at(end);
        text = rest;
        Some(chunk)
    })
}
async fn next(events: &mut reis::tokio::EiEventStream) -> Result<ei::Event> {
    match events
        .next()
        .await
        .ok_or_else(|| anyhow::anyhow!("EIS closed"))??
    {
        PendingRequestResult::Request(event) => Ok(event),
        _ => bail!("invalid EIS protocol message"),
    }
}
fn monotonic_micros() -> u64 {
    let mut t = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // CLOCK_MONOTONIC's timespec is initialized and valid for this call.
    unsafe {
        libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut t);
    }
    t.tv_sec as u64 * 1_000_000 + t.tv_nsec as u64 / 1000
}

#[derive(Default)]
struct Selection {
    offered: Option<Vec<String>>,
    owner: bool,
    ownership_known: bool,
    generation: u64,
    revision: u64,
    served: BTreeMap<String, Vec<u8>>,
    saved: Option<(u64, BTreeMap<String, Vec<u8>>)>,
}
impl Selection {
    fn take_restore(&mut self, id: u64) -> Option<BTreeMap<String, Vec<u8>>> {
        if self.generation != id {
            return None;
        }
        let saved = self.saved.take();
        if !self.owner {
            return None;
        }
        saved
            .filter(|(generation, _)| *generation == id)
            .map(|(_, data)| data)
    }
}
struct PortalClipboard {
    proxy: Arc<Clipboard>,
    shared: Arc<Mutex<Selection>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}
impl Drop for PortalClipboard {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}
impl PortalClipboard {
    async fn open(connection: zbus::Connection, session: &Session<RemoteDesktop>) -> Result<Self> {
        let proxy = Arc::new(Clipboard::with_connection(connection).await?);
        let shared = Arc::new(Mutex::new(Selection::default()));
        let state = shared.clone();
        let path = serde_json::to_string(session)?;
        let p = proxy.clone();
        let (owner_ready, owner_wait) = tokio::sync::oneshot::channel();
        let owners = tokio::spawn(async move {
            let stream = match p.receive_selection_owner_changed::<RemoteDesktop>().await {
                Ok(s) => s,
                Err(_) => {
                    let _ = owner_ready.send(false);
                    return;
                }
            };
            let mut owners = Box::pin(stream);
            let _ = owner_ready.send(true);
            while let Some((session, changed)) = owners.next().await {
                if serde_json::to_string(&session).ok().as_ref() != Some(&path) {
                    continue;
                }
                let mut state = state.lock().unwrap();
                state.revision += 1;
                state.ownership_known = changed.session_is_owner().is_some();
                state.owner = changed.session_is_owner() == Some(true);
                state.offered = Some(changed.mime_types().to_vec());
                if !state.owner {
                    state.served.clear();
                }
            }
        });
        let state = shared.clone();
        let p = proxy.clone();
        let path = serde_json::to_string(session)?;
        let (transfer_ready, transfer_wait) = tokio::sync::oneshot::channel();
        let transfers = tokio::spawn(async move {
            let stream = match p.receive_selection_transfer::<RemoteDesktop>().await {
                Ok(s) => s,
                Err(_) => {
                    let _ = transfer_ready.send(false);
                    return;
                }
            };
            let mut transfers = Box::pin(stream);
            let _ = transfer_ready.send(true);
            while let Some((session, mime, serial)) = transfers.next().await {
                if serde_json::to_string(&session).ok().as_ref() != Some(&path) {
                    continue;
                }
                let bytes = {
                    let state = state.lock().unwrap();
                    state.served.get(&mime).cloned()
                };
                let result: Result<()> = timeout(IO_TIME, async {
                    let bytes = bytes.ok_or_else(|| anyhow::anyhow!("unknown format"))?;
                    let fd = p.selection_write(&session, serial).await?;
                    write_fd(fd.into(), &bytes).await
                })
                .await
                .unwrap_or_else(|_| Err(anyhow::anyhow!("clipboard write timeout")));
                let _ = p
                    .selection_write_done(&session, serial, result.is_ok())
                    .await;
            }
        });
        let result = Self {
            proxy,
            shared,
            tasks: vec![owners, transfers],
        };
        ensure!(
            owner_wait.await? && transfer_wait.await?,
            "clipboard signal subscription failed"
        );
        result.proxy.request(session, Default::default()).await?;
        Ok(result)
    }
    async fn snapshot(
        &self,
        session: &Session<RemoteDesktop>,
    ) -> Result<BTreeMap<String, Vec<u8>>> {
        let (offered, owned, current, generation) = {
            let s = self.shared.lock().unwrap();
            ensure!(s.ownership_known, "clipboard ownership unknown");
            (s.offered.clone(), s.owner, s.served.clone(), s.revision)
        };
        if owned {
            return Ok(current);
        }
        let offered = offered.ok_or_else(|| anyhow::anyhow!("clipboard owner unknown"))?;
        ensure!(offered.len() <= 256, "too many clipboard formats");
        let mut saved = BTreeMap::new();
        let mut size = 0;
        for mime in &offered {
            let fd = self.proxy.selection_read(session, mime).await?;
            let bytes = read_fd(fd.into(), CAP - size).await?;
            size += bytes.len();
            saved.insert(mime.clone(), bytes);
        }
        let s = self.shared.lock().unwrap();
        ensure!(
            s.revision == generation && s.offered.as_ref() == Some(&offered) && !s.owner,
            "clipboard changed during snapshot"
        );
        Ok(saved)
    }
    async fn set(
        &self,
        session: &Session<RemoteDesktop>,
        data: BTreeMap<String, Vec<u8>>,
    ) -> Result<()> {
        let revision = self.shared.lock().unwrap().revision;
        let types: Vec<String> = data.keys().cloned().collect();
        {
            self.shared.lock().unwrap().served = data;
        }
        let types: Vec<&str> = types.iter().map(String::as_str).collect();
        timeout(
            IO_TIME,
            self.proxy.set_selection(
                session,
                SetSelectionOptions::default().set_mime_types(&types),
            ),
        )
        .await??;
        // A signal acknowledging ownership is required before input.
        for _ in 0..100 {
            {
                let state = self.shared.lock().unwrap();
                if state.owner && state.revision != revision {
                    return Ok(());
                }
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        bail!("clipboard ownership not acknowledged")
    }
    async fn install(
        &self,
        session: &Session<RemoteDesktop>,
        text: &str,
        saved: BTreeMap<String, Vec<u8>>,
    ) -> Result<u64> {
        crate::validate_text(text)?;
        let id = {
            let mut s = self.shared.lock().unwrap();
            s.generation += 1;
            s.generation
        };
        // Save snapshot in memory separately from the formats served to apps.
        self.saved_set(id, saved);
        let formats = BTreeMap::from([
            ("text/plain;charset=utf-8".into(), text.as_bytes().to_vec()),
            ("text/plain".into(), text.as_bytes().to_vec()),
        ]);
        if let Err(error) = self.set(session, formats).await {
            let _ = self.finish(session, id, false).await;
            return Err(error);
        }
        Ok(id)
    }
    fn saved_set(&self, id: u64, data: BTreeMap<String, Vec<u8>>) {
        // Kept in the same synchronized state to avoid cross-session restoration.
        let mut s = self.shared.lock().unwrap();
        s.saved = Some((id, data));
    }
    async fn finish(&self, session: &Session<RemoteDesktop>, id: u64, sent: bool) -> Result<bool> {
        if sent {
            crate::paste::wait().await;
        }
        // Ownership/generation checks protect newer copies. A transfer already
        // in progress owns its byte snapshot independently of this restoration.
        let consumed = false;
        let saved = {
            let mut s = self.shared.lock().unwrap();
            s.take_restore(id)
        };
        if let Some(saved) = saved {
            if let Err(error) = self.set(session, saved.clone()).await {
                self.saved_set(id, saved);
                return Err(error);
            }
        }
        Ok(consumed)
    }
}

fn nonblocking(fd: OwnedFd) -> Result<AsyncFd<OwnedFd>> {
    // Own the descriptor; retaining existing flags avoids changing its access mode.
    unsafe {
        let flags = libc::fcntl(fd.as_raw_fd(), libc::F_GETFL);
        ensure!(
            flags >= 0 && libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) >= 0,
            "cannot set nonblocking pipe"
        );
    }
    // OwnedFd keeps the descriptor open and stable for the AsyncFd lifetime.
    Ok(unsafe { AsyncFd::register(fd)? })
}
async fn read_fd(fd: OwnedFd, cap: usize) -> Result<Vec<u8>> {
    let fd = nonblocking(fd)?;
    let mut bytes = Vec::new();
    loop {
        let mut ready = fd.readable().await?;
        let mut buffer = [0u8; 8192];
        let n = match ready.try_io(|fd| {
            let n = unsafe { libc::read(fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
            if n < 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(n as usize)
            }
        }) {
            Ok(n) => n?,
            Err(_) => continue,
        };
        if n == 0 {
            return Ok(bytes);
        }
        ensure!(bytes.len() + n <= cap, "clipboard exceeds size limit");
        bytes.extend_from_slice(&buffer[..n]);
    }
}
async fn write_fd(fd: OwnedFd, mut bytes: &[u8]) -> Result<()> {
    let fd = nonblocking(fd)?;
    while !bytes.is_empty() {
        let mut ready = fd.writable().await?;
        let n = match ready.try_io(|fd| {
            let n = unsafe { libc::write(fd.as_raw_fd(), bytes.as_ptr().cast(), bytes.len()) };
            if n < 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(n as usize)
            }
        }) {
            Ok(n) => n?,
            Err(_) => continue,
        };
        ensure!(n > 0, "short clipboard write");
        bytes = &bytes[n..];
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use reis::eis;
    use std::{os::unix::net::UnixStream, time::Instant};
    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
    }
    fn next_request(context: &eis::Context) -> eis::Request {
        let end = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(Instant::now() < end, "fake EIS timed out");
            if let Some(event) = context.pending_request() {
                return match event {
                    PendingRequestResult::Request(r) => r,
                    _ => panic!("invalid client protocol"),
                };
            }
            context.read().unwrap();
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    pub(super) fn fake_eis(socket: UnixStream, ack: bool) -> String {
        fake_eis_repeated(socket, ack, 1)
    }
    pub(super) fn fake_eis_repeated(socket: UnixStream, ack: bool, repeats: usize) -> String {
        fake_server(socket, ack, repeats, false, None)
    }
    pub(super) fn fake_keyboard(socket: UnixStream) -> String {
        fake_server(socket, true, 2, true, None)
    }
    pub(super) fn fake_idle_ping(
        socket: UnixStream,
        pongs: Arc<std::sync::atomic::AtomicUsize>,
    ) -> String {
        fake_server(socket, true, 2, false, Some(pongs))
    }
    fn fake_server(
        socket: UnixStream,
        ack: bool,
        repeats: usize,
        keyboard_only: bool,
        pongs: Option<Arc<std::sync::atomic::AtomicUsize>>,
    ) -> String {
        let c = eis::Context::new(socket).unwrap();
        let mut handshake = reis::handshake::EisHandshaker::new(&c, 1);
        let connection = loop {
            if let Some(response) = handshake.handle_request(next_request(&c)).unwrap() {
                assert_eq!(response.context_type, eis::handshake::ContextType::Sender);
                break response.connection;
            }
        };
        let seat = connection.seat(1);
        seat.capability(
            1,
            if keyboard_only {
                "ei_keyboard"
            } else {
                "ei_text"
            },
        );
        seat.done();
        c.flush().unwrap();
        match next_request(&c) {
            eis::Request::Seat(_, eis::seat::Request::Bind { capabilities }) => {
                assert_eq!(capabilities, 1)
            }
            _ => panic!("expected text bind"),
        }
        let device = seat.device(1);
        device.device_type(eis::device::DeviceType::Virtual);
        let mut keymap_file = None;
        let layout = crate::keymap::fixture("dvorak");
        if keyboard_only {
            use std::{io::Write, os::fd::AsFd};
            let keyboard = device.interface::<eis::Keyboard>(1);
            let mut file = tempfile::tempfile().unwrap();
            file.write_all(&layout).unwrap();
            // The protocol supplies an mmap-able FD, not a promised file offset.
            keyboard.keymap(
                eis::keyboard::KeymapType::Xkb,
                layout.len() as u32,
                file.as_fd(),
            );
            keymap_file = Some(file);
        } else {
            let _ = device.interface::<eis::Text>(1);
        }
        device.done();
        device.resumed(2);
        c.flush().unwrap();
        let mut output = String::new();
        let mut completed = 0;
        let mut pending_text = false;
        let mut started = false;
        let layout = crate::keymap::Keymap::parse(&layout).unwrap();
        let mut key_events = Vec::new();
        let _keep_keymap = keymap_file;
        loop {
            match next_request(&c) {
                eis::Request::Device(_, eis::device::Request::StartEmulating { .. }) => {
                    started = true
                }
                eis::Request::Text(_, eis::text::Request::Utf8 { text }) => {
                    assert!(started && !pending_text);
                    assert!(!text.is_empty() && text.len() <= 254);
                    crate::validate_text(&text).unwrap();
                    output.push_str(&text);
                    pending_text = true;
                }
                eis::Request::Keyboard(_, eis::keyboard::Request::Key { key, state })
                    if keyboard_only =>
                {
                    assert!(started);
                    key_events.push((key, state));
                    pending_text = true;
                }
                eis::Request::Device(_, eis::device::Request::Frame { .. }) => {
                    assert!(pending_text);
                    pending_text = false;
                }
                eis::Request::Device(_, eis::device::Request::StopEmulating { .. }) => {
                    assert!(!pending_text);
                    started = false;
                }
                eis::Request::Connection(_, eis::connection::Request::Sync { callback }) => {
                    assert!(!started);
                    if ack {
                        callback.done(0);
                        c.flush().unwrap();
                        if completed + 1 == repeats {
                            std::thread::sleep(Duration::from_millis(100));
                        }
                    }
                    if keyboard_only {
                        let expected = layout.paste(true, 0).unwrap();
                        let down: Vec<_> = expected
                            .iter()
                            .map(|key| (*key, eis::keyboard::KeyState::Press))
                            .collect();
                        let up: Vec<_> = expected
                            .iter()
                            .rev()
                            .map(|key| (*key, eis::keyboard::KeyState::Released))
                            .collect();
                        assert_eq!(
                            key_events,
                            [down, up].concat(),
                            "use compositor layout and never Return/Tab"
                        );
                        key_events.clear();
                    }
                    completed += 1;
                    if completed < repeats && pongs.is_some() {
                        let _ = connection.ping(1);
                        c.flush().unwrap();
                    }
                    if completed == repeats || !ack {
                        return output;
                    }
                }
                eis::Request::Pingpong(_, eis::pingpong::Request::Done { .. }) => {
                    if let Some(pongs) = &pongs {
                        pongs.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    }
                }
                _ => panic!("unexpected request: keys must never be sent"),
            }
        }
    }
    #[test]
    fn libei_wire_unicode_frames_and_roundtrip() {
        let (client, server) = UnixStream::pair().unwrap();
        let server = std::thread::spawn(move || fake_eis(server, true));
        let text = "synthetic é 日本語 🦀 ".repeat(100);
        runtime().block_on(async {
            let mut eis = timeout(IO_TIME, Eis::open(client.into()))
                .await
                .unwrap()
                .unwrap();
            timeout(IO_TIME, eis.send(&text)).await.unwrap().unwrap();
        });
        assert_eq!(server.join().unwrap(), text);
    }
    #[test]
    fn libei_disconnect_after_input_is_error_not_success() {
        let (client, server) = UnixStream::pair().unwrap();
        let server = std::thread::spawn(move || fake_eis(server, false));
        runtime().block_on(async {
            let mut eis = timeout(IO_TIME, Eis::open(client.into()))
                .await
                .unwrap()
                .unwrap();
            assert!(
                timeout(IO_TIME, eis.send("synthetic"))
                    .await
                    .unwrap()
                    .is_err()
            );
        });
        assert_eq!(server.join().unwrap(), "synthetic");
    }
    #[test]
    fn portal_pipe_preserves_bytes_and_bounds_reads() {
        runtime().block_on(async {
            let (a, b) = UnixStream::pair().unwrap();
            let data = "synthetic é 日本語".as_bytes();
            let (write, read) = tokio::join!(write_fd(a.into(), data), read_fd(b.into(), 1024));
            write.unwrap();
            assert_eq!(read.unwrap(), data);
            let (a, b) = UnixStream::pair().unwrap();
            let (write, read) = tokio::join!(write_fd(a.into(), data), read_fd(b.into(), 2));
            write.unwrap();
            assert!(read.is_err());
        });
    }
    #[test]
    fn permission_token_storage_is_private_and_durable() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let store = FileKeyStore::new(temp.path().join("linux-input")).unwrap();
        store.put(TOKEN, b"synthetic-permission-fixture").unwrap();
        drop(store);
        let store = FileKeyStore::new(temp.path().join("linux-input")).unwrap();
        assert_eq!(
            store.get(TOKEN).unwrap().unwrap().as_slice(),
            b"synthetic-permission-fixture"
        );
        assert_eq!(
            std::fs::metadata(temp.path().join("linux-input").join(TOKEN))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}

#[cfg(test)]
pub(crate) mod dbus_tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader},
        process::{Child, Command, Stdio},
    };
    use zbus::{
        fdo,
        zvariant::{OwnedObjectPath, OwnedValue, Value},
    };
    type Options = HashMap<String, OwnedValue>;
    #[derive(Default)]
    struct Calls {
        restore: Vec<Option<String>>,
        keys: Vec<(i32, u32)>,
        deny: bool,
        fail_v: bool,
        starts: u32,
        clipboard: bool,
        eis_sessions: std::collections::HashSet<OwnedObjectPath>,
        eis_calls: usize,
        keyboard_only: bool,
        pongs: Arc<std::sync::atomic::AtomicUsize>,
    }
    struct FakeRemote(Arc<Mutex<Calls>>);
    struct FakeSession;
    #[zbus::interface(name = "org.freedesktop.portal.Session")]
    impl FakeSession {
        async fn close(&self) {}
        #[zbus(property, name = "version")]
        fn version(&self) -> u32 {
            1
        }
    }
    fn string(options: &Options, key: &str) -> Option<String> {
        options
            .get(key)
            .and_then(|v| <&str>::try_from(v).ok())
            .map(str::to_owned)
    }
    async fn respond(
        c: &zbus::Connection,
        header: &zbus::message::Header<'_>,
        options: &Options,
        code: u32,
        values: Options,
    ) -> fdo::Result<OwnedObjectPath> {
        let sender = header.sender().unwrap().as_str();
        let name = sender.trim_start_matches(':').replace('.', "_");
        let token = string(options, "handle_token").unwrap();
        let path = OwnedObjectPath::try_from(format!(
            "/org/freedesktop/portal/desktop/request/{name}/{token}"
        ))
        .unwrap();
        c.emit_signal(
            Some(sender),
            path.as_str(),
            "org.freedesktop.portal.Request",
            "Response",
            &(code, values),
        )
        .await?;
        Ok(path)
    }
    fn value(v: Value<'_>) -> OwnedValue {
        v.try_to_owned().unwrap()
    }
    #[zbus::interface(name = "org.freedesktop.portal.RemoteDesktop")]
    impl FakeRemote {
        #[zbus(property, name = "version")]
        fn version(&self) -> u32 {
            2
        }
        async fn create_session(
            &self,
            options: Options,
            #[zbus(connection)] c: &zbus::Connection,
            #[zbus(header)] h: zbus::message::Header<'_>,
        ) -> fdo::Result<OwnedObjectPath> {
            let sender = h
                .sender()
                .unwrap()
                .as_str()
                .trim_start_matches(':')
                .replace('.', "_");
            let token = string(&options, "session_handle_token").unwrap();
            let session = format!("/org/freedesktop/portal/desktop/session/{sender}/{token}");
            c.object_server().at(session.as_str(), FakeSession).await?;
            respond(
                c,
                &h,
                &options,
                0,
                HashMap::from([(
                    "session_handle".into(),
                    value(Value::from(session.as_str())),
                )]),
            )
            .await
        }
        async fn select_devices(
            &self,
            _session: OwnedObjectPath,
            options: Options,
            #[zbus(connection)] c: &zbus::Connection,
            #[zbus(header)] h: zbus::message::Header<'_>,
        ) -> fdo::Result<OwnedObjectPath> {
            assert_eq!(
                options.get("types").and_then(|v| u32::try_from(v).ok()),
                Some(1)
            );
            assert_eq!(
                options
                    .get("persist_mode")
                    .and_then(|v| u32::try_from(v).ok()),
                Some(2)
            );
            self.0
                .lock()
                .unwrap()
                .restore
                .push(string(&options, "restore_token"));
            respond(c, &h, &options, 0, HashMap::new()).await
        }
        async fn start(
            &self,
            _session: OwnedObjectPath,
            _parent: String,
            options: Options,
            #[zbus(connection)] c: &zbus::Connection,
            #[zbus(header)] h: zbus::message::Header<'_>,
        ) -> fdo::Result<OwnedObjectPath> {
            let (deny, token) = {
                let mut calls = self.0.lock().unwrap();
                calls.starts += 1;
                (calls.deny, format!("synthetic-permission-{}", calls.starts))
            };
            let clipboard = self.0.lock().unwrap().clipboard;
            respond(
                c,
                &h,
                &options,
                if deny { 1 } else { 0 },
                HashMap::from([
                    ("devices".into(), value(Value::from(1u32))),
                    ("restore_token".into(), value(Value::from(token.as_str()))),
                    ("clipboard_enabled".into(), value(Value::from(clipboard))),
                ]),
            )
            .await
        }
        #[zbus(name = "ConnectToEIS")]
        async fn connect_to_eis(
            &self,
            session: OwnedObjectPath,
            _options: Options,
        ) -> fdo::Result<zbus::zvariant::OwnedFd> {
            let mut calls = self.0.lock().unwrap();
            calls.eis_calls += 1;
            if !calls.eis_sessions.insert(session) {
                return Err(fdo::Error::Failed("ConnectToEIS once per session".into()));
            }
            let (client, server) = std::os::unix::net::UnixStream::pair().unwrap();
            let keyboard_only = calls.keyboard_only;
            let pongs = calls.pongs.clone();
            std::thread::spawn(move || {
                if keyboard_only {
                    super::tests::fake_keyboard(server)
                } else {
                    super::tests::fake_idle_ping(server, pongs)
                }
            });
            Ok(OwnedFd::from(client).into())
        }
        async fn notify_keyboard_keysym(
            &self,
            _session: OwnedObjectPath,
            _options: Options,
            key: i32,
            state: u32,
        ) -> fdo::Result<()> {
            let mut calls = self.0.lock().unwrap();
            if calls.eis_sessions.contains(&_session) {
                return Err(fdo::Error::Failed("Notify forbidden after EIS".into()));
            }
            calls.keys.push((key, state));
            if calls.fail_v && key == b'v' as i32 && state == 1 {
                return Err(fdo::Error::Failed("synthetic failure".into()));
            }
            Ok(())
        }
    }

    #[derive(Default)]
    struct ClipboardCalls {
        formats: BTreeMap<String, Vec<u8>>,
        sets: Vec<Vec<String>>,
        reader: Option<std::os::unix::net::UnixStream>,
        done: Vec<bool>,
    }
    struct FakeClipboard(Arc<Mutex<ClipboardCalls>>);
    async fn owner_changed(
        c: &zbus::Connection,
        session: &OwnedObjectPath,
        formats: Vec<String>,
        owner: bool,
    ) {
        c.emit_signal(
            None::<&str>,
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Clipboard",
            "SelectionOwnerChanged",
            &(
                session,
                HashMap::from([
                    ("mime_types", value(Value::from(formats))),
                    ("session_is_owner", value(Value::from(owner))),
                ]),
            ),
        )
        .await
        .unwrap();
    }
    #[zbus::interface(name = "org.freedesktop.portal.Clipboard")]
    impl FakeClipboard {
        #[zbus(property, name = "version")]
        fn version(&self) -> u32 {
            1
        }
        async fn request_clipboard(
            &self,
            session: OwnedObjectPath,
            _options: Options,
            #[zbus(connection)] c: &zbus::Connection,
        ) {
            let formats = self.0.lock().unwrap().formats.keys().cloned().collect();
            owner_changed(c, &session, formats, false).await;
        }
        async fn selection_read(
            &self,
            _session: OwnedObjectPath,
            mime: String,
        ) -> zbus::zvariant::OwnedFd {
            use std::io::Write;
            let bytes = self.0.lock().unwrap().formats[&mime].clone();
            let (reader, mut writer) = std::os::unix::net::UnixStream::pair().unwrap();
            std::thread::spawn(move || {
                writer.write_all(&bytes).unwrap();
            });
            OwnedFd::from(reader).into()
        }
        async fn set_selection(
            &self,
            session: OwnedObjectPath,
            options: Options,
            #[zbus(connection)] c: &zbus::Connection,
        ) {
            let types = options
                .get("mime_types")
                .map(|v| Vec::<String>::try_from(v.try_clone().unwrap()).unwrap())
                .unwrap_or_default();
            self.0.lock().unwrap().sets.push(types.clone());
            owner_changed(c, &session, types, true).await;
        }
        async fn selection_write(
            &self,
            _session: OwnedObjectPath,
            _serial: u32,
        ) -> zbus::zvariant::OwnedFd {
            let (reader, writer) = std::os::unix::net::UnixStream::pair().unwrap();
            self.0.lock().unwrap().reader = Some(reader);
            OwnedFd::from(writer).into()
        }
        async fn selection_write_done(
            &self,
            _session: OwnedObjectPath,
            _serial: u32,
            success: bool,
        ) {
            self.0.lock().unwrap().done.push(success);
        }
    }
    async fn receive_bytes(
        server: &zbus::Connection,
        portal: &Portal,
        calls: &Mutex<ClipboardCalls>,
        mime: &str,
    ) -> Vec<u8> {
        let path: OwnedObjectPath =
            serde_json::from_str(&serde_json::to_string(&portal.session).unwrap()).unwrap();
        server
            .emit_signal(
                None::<&str>,
                "/org/freedesktop/portal/desktop",
                "org.freedesktop.portal.Clipboard",
                "SelectionTransfer",
                &(path, mime, 42u32),
            )
            .await
            .unwrap();
        let reader = timeout(IO_TIME, async {
            loop {
                if let Some(reader) = calls.lock().unwrap().reader.take() {
                    break reader;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .unwrap();
        timeout(IO_TIME, read_fd(reader.into(), CAP))
            .await
            .unwrap()
            .unwrap()
    }
    #[test]
    fn portal_clipboard_protocol_restores_binary_formats_and_preserves_new_copy() {
        let bus = Bus::new();
        let temp = tempfile::tempdir().unwrap();
        let remote_calls = Arc::new(Mutex::new(Calls {
            clipboard: true,
            ..Default::default()
        }));
        let formats = BTreeMap::from([
            ("text/plain".into(), b"synthetic old clipboard".to_vec()),
            ("image/png".into(), vec![0, 1, 2, 255]),
            ("text/html".into(), b"<b>synthetic</b>".to_vec()),
        ]);
        let clip_calls = Arc::new(Mutex::new(ClipboardCalls {
            formats: formats.clone(),
            ..Default::default()
        }));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let server = bus.connection().await;
            server
                .request_name("org.freedesktop.portal.Desktop")
                .await
                .unwrap();
            server
                .object_server()
                .at("/org/freedesktop/portal/desktop", FakeRemote(remote_calls))
                .await
                .unwrap();
            server
                .object_server()
                .at(
                    "/org/freedesktop/portal/desktop",
                    FakeClipboard(clip_calls.clone()),
                )
                .await
                .unwrap();
            let portal = Portal::open_with_connection(temp.path(), bus.connection().await)
                .await
                .unwrap();
            let saved = portal.prepare_clipboard().await.unwrap();
            assert_eq!(saved, formats);
            let id = portal
                .install_clipboard("synthetic 日本語 🦀", saved)
                .await
                .unwrap();
            assert_eq!(
                receive_bytes(&server, &portal, &clip_calls, "text/plain").await,
                "synthetic 日本語 🦀".as_bytes()
            );
            // Reads, including a manager's, cannot shorten the 30-second lease.
            let completion = portal.finish_clipboard(id, true);
            tokio::pin!(completion);
            assert!(
                timeout(Duration::from_millis(300), &mut completion)
                    .await
                    .is_err()
            );
            assert_eq!(
                receive_bytes(&server, &portal, &clip_calls, "text/plain").await,
                "synthetic 日本語 🦀".as_bytes()
            );
            // Advance only the lease clock; the protocol fake still requires
            // the complete saved formats to be re-offered automatically.
            tokio::time::pause();
            tokio::time::advance(Duration::from_secs(30)).await;
            tokio::time::resume();
            assert!(!completion.await.unwrap()); // restored, never confirmed
            for (mime, bytes) in &formats {
                assert_eq!(
                    &receive_bytes(&server, &portal, &clip_calls, mime).await,
                    bytes
                );
            }
            let saved = portal.prepare_clipboard().await.unwrap();
            let id = portal
                .install_clipboard("synthetic second", saved)
                .await
                .unwrap();
            let count = clip_calls.lock().unwrap().sets.len();
            let path: OwnedObjectPath =
                serde_json::from_str(&serde_json::to_string(&portal.session).unwrap()).unwrap();
            owner_changed(&server, &path, vec!["text/plain".into()], false).await;
            tokio::time::sleep(Duration::from_millis(10)).await;
            assert!(!portal.finish_clipboard(id, false).await.unwrap());
            assert_eq!(clip_calls.lock().unwrap().sets.len(), count);
        });
    }
    pub(crate) struct Bus {
        child: Child,
        address: String,
        _config: tempfile::TempDir,
    }
    impl Bus {
        pub(crate) fn new() -> Self {
            let config = tempfile::tempdir().unwrap();
            let path = config.path().join("bus.conf");
            std::fs::write(&path, r#"<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth><apparmor mode="disabled"/><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>"#).unwrap();
            let mut child = Command::new("dbus-daemon")
                .arg("--config-file")
                .arg(path)
                .args(["--nofork", "--print-address=1"])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .expect("dbus-daemon required for protocol doubles");
            let mut address = String::new();
            BufReader::new(child.stdout.take().unwrap())
                .read_line(&mut address)
                .unwrap();
            Self {
                child,
                address: address.trim().into(),
                _config: config,
            }
        }
        pub(crate) async fn connection(&self) -> zbus::Connection {
            zbus::connection::Builder::address(self.address.as_str())
                .unwrap()
                .build()
                .await
                .unwrap()
        }
    }
    impl Drop for Bus {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
    #[test]
    fn gnome_without_ei_text_uses_persistent_eis_keyboard_and_never_notify() {
        let bus = Bus::new();
        let temp = tempfile::tempdir().unwrap();
        let calls = Arc::new(Mutex::new(Calls {
            keyboard_only: true,
            ..Default::default()
        }));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let server = bus.connection().await;
            server
                .request_name("org.freedesktop.portal.Desktop")
                .await
                .unwrap();
            server
                .object_server()
                .at("/org/freedesktop/portal/desktop", FakeRemote(calls.clone()))
                .await
                .unwrap();
            let mut portal = Portal::open_with_connection(temp.path(), bus.connection().await)
                .await
                .unwrap();
            for _ in 0..2 {
                let eis = timeout(IO_TIME, portal.eis()).await.unwrap().unwrap();
                assert!(!eis.supports_text());
                assert!(portal.can_paste(true));
                timeout(IO_TIME, portal.paste(true)).await.unwrap().unwrap();
            }
            assert_eq!(calls.lock().unwrap().eis_calls, 1);
            assert!(
                calls.lock().unwrap().keys.is_empty(),
                "Notify must never follow EIS"
            );
        });
    }
    #[test]
    fn regression_portal_reuses_once_per_session_eis() {
        let bus = Bus::new();
        let temp = tempfile::tempdir().unwrap();
        let calls = Arc::new(Mutex::new(Calls::default()));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let server = bus.connection().await;
            server
                .request_name("org.freedesktop.portal.Desktop")
                .await
                .unwrap();
            server
                .object_server()
                .at("/org/freedesktop/portal/desktop", FakeRemote(calls.clone()))
                .await
                .unwrap();
            let mut portal = Portal::open_with_connection(temp.path(), bus.connection().await)
                .await
                .unwrap();
            for index in 0..2 {
                let eis = timeout(IO_TIME, portal.eis()).await.unwrap().unwrap();
                timeout(IO_TIME, eis.send("synthetic repeated"))
                    .await
                    .unwrap()
                    .unwrap();
                if index == 0 {
                    // No new insert to drive reads: the idle actor must answer.
                    timeout(IO_TIME, async {
                        loop {
                            if calls
                                .lock()
                                .unwrap()
                                .pongs
                                .load(std::sync::atomic::Ordering::SeqCst)
                                > 0
                            {
                                break;
                            }
                            tokio::time::sleep(Duration::from_millis(5)).await;
                        }
                    })
                    .await
                    .unwrap();
                }
            }
            assert_eq!(calls.lock().unwrap().eis_calls, 1);
        });
    }
    #[test]
    fn portal_protocol_rotates_token_and_never_emits_submit_keys() {
        let bus = Bus::new();
        let temp = tempfile::tempdir().unwrap();
        let calls = Arc::new(Mutex::new(Calls::default()));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let server = bus.connection().await;
            server
                .request_name("org.freedesktop.portal.Desktop")
                .await
                .unwrap();
            server
                .object_server()
                .at("/org/freedesktop/portal/desktop", FakeRemote(calls.clone()))
                .await
                .unwrap();
            for _ in 0..2 {
                let mut portal = timeout(
                    Duration::from_secs(5),
                    Portal::open_with_connection(temp.path(), bus.connection().await),
                )
                .await
                .unwrap()
                .unwrap();
                portal.paste(false).await.unwrap();
            }
            let before = calls.lock().unwrap().keys.len();
            let mut portal = Portal::open_with_connection(temp.path(), bus.connection().await)
                .await
                .unwrap();
            portal.paste(true).await.unwrap();
            assert!(
                calls.lock().unwrap().keys[before..].contains(&(0xffe1, 1)),
                "terminal paste must press Shift"
            );
            let state = calls.lock().unwrap();
            assert_eq!(
                state.restore,
                [
                    None,
                    Some("synthetic-permission-1".into()),
                    Some("synthetic-permission-2".into())
                ]
            );
            assert!(
                state
                    .keys
                    .iter()
                    .all(|(key, _)| [0xffe3, 0xffe1, 0x76].contains(key))
            );
            assert_eq!(state.keys.last(), Some(&(0xffe3, 0)));
            drop(state);
            calls.lock().unwrap().fail_v = true;
            let mut portal = Portal::open_with_connection(temp.path(), bus.connection().await)
                .await
                .unwrap();
            assert!(portal.paste(false).await.is_err());
            assert_eq!(calls.lock().unwrap().keys.last(), Some(&(0xffe3, 0)));
            calls.lock().unwrap().deny = true;
            assert!(
                Portal::open_with_connection(temp.path(), bus.connection().await)
                    .await
                    .is_err()
            );
            let store = FileKeyStore::new(temp.path().join("linux-input")).unwrap();
            assert!(store.get(TOKEN).unwrap().is_none());
        });
    }
    #[test]
    fn clipboard_restore_retains_all_formats_and_respects_new_owners_and_generations() {
        let formats = BTreeMap::from([
            ("text/plain".into(), b"synthetic".to_vec()),
            ("image/png".into(), vec![1, 2, 3]),
            ("text/html".into(), b"<b>fixture</b>".to_vec()),
        ]);
        let mut s = Selection {
            owner: true,
            generation: 2,
            saved: Some((2, formats.clone())),
            ..Default::default()
        };
        assert!(s.take_restore(1).is_none());
        assert!(s.saved.is_some());
        assert_eq!(s.take_restore(2), Some(formats.clone()));
        assert!(s.saved.is_none());
        s.saved = Some((2, formats));
        s.owner = false;
        assert!(s.take_restore(2).is_none());
        assert!(s.saved.is_none());
        s.owner = true;
        s.saved = Some((2, BTreeMap::new()));
        assert_eq!(s.take_restore(2), Some(BTreeMap::new()));
    }
}
