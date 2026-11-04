//! Shared with the CLI by path: bounded, user-only local capture requests.
use anyhow::{Result, ensure};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::{mpsc, oneshot},
};
use voiceremote_core::protocol::*;

pub struct Toggle {
    pub expires: tokio::time::Instant,
    pub reply: oneshot::Sender<bool>,
}
#[allow(dead_code)] // The CLI only uses the transport; the GUI reads this snapshot.
#[derive(Clone, Default, serde::Serialize)]
pub struct Status {
    pub connected: bool,
    pub mode: Option<Mode>,
    pub capture: Option<CaptureState>,
    pub destination: Option<String>,
    pub flash: u64,
    pub listening: Option<bool>,
}
#[derive(Default)]
pub struct Hub {
    next: u64,
    gesture: CaptureTrigger,
    gesture_context: Option<(u64, Option<Mode>, Option<CaptureState>)>,
    sessions: BTreeMap<u64, mpsc::Sender<Toggle>>,
    pub status: Status,
    pub presentation_required: bool,
    presentation: Option<(u64, oneshot::Sender<bool>)>,
    pub revocations: BTreeMap<String, oneshot::Sender<bool>>,
}
impl Hub {
    pub fn clear_gesture(&mut self) {
        self.gesture = CaptureTrigger::default();
        self.gesture_context = None;
    }
    #[allow(dead_code)] // Read by the GUI, not the CLI.
    pub fn snapshot(&self) -> Status {
        if self.sessions.len() == 1 {
            self.status.clone()
        } else {
            Status {
                connected: !self.sessions.is_empty(),
                ..Status::default()
            }
        }
    }
}
/// A GUI completes this only after successfully showing the tray/overlay.
/// A stalled or unavailable GUI refuses preparation; text cannot overtake it.
pub async fn present(hub: &Arc<Mutex<Hub>>, destination: String) -> bool {
    let receive = {
        let mut h = hub.lock().unwrap();
        h.status.destination = Some(destination);
        h.status.flash = h.status.flash.wrapping_add(1);
        if !h.presentation_required {
            // CLI presentation has no GUI event loop. Output contains no field data.
            eprintln!("Voice Receiver selected for dictation");
            return true;
        }
        let (reply, receive) = oneshot::channel();
        let sequence = h.status.flash;
        h.presentation = Some((sequence, reply));
        receive
    };
    tokio::time::timeout(Duration::from_secs(2), receive)
        .await
        .is_ok_and(|result| result == Ok(true))
}
#[allow(dead_code)] // The GUI acknowledges presentation; the CLI prints directly.
pub fn presented(hub: &Arc<Mutex<Hub>>, sequence: u64, ready: bool) {
    let mut h = hub.lock().unwrap();
    if h.presentation
        .as_ref()
        .is_some_and(|(pending, _)| *pending == sequence)
    {
        if let Some((_, reply)) = h.presentation.take() {
            let _ = reply.send(ready);
        }
    }
}
pub fn hub() -> &'static Arc<Mutex<Hub>> {
    static HUB: OnceLock<Arc<Mutex<Hub>>> = OnceLock::new();
    HUB.get_or_init(Default::default)
}
pub struct Registration {
    hub: Arc<Mutex<Hub>>,
    id: u64,
}
impl Drop for Registration {
    fn drop(&mut self) {
        let mut hub = self.hub.lock().unwrap();
        hub.sessions.remove(&self.id);
        hub.clear_gesture();
        hub.status = Status {
            connected: !hub.sessions.is_empty(),
            ..Status::default()
        };
    }
}
pub fn register(hub: Arc<Mutex<Hub>>) -> (Registration, mpsc::Receiver<Toggle>) {
    let (tx, rx) = mpsc::channel(1);
    let id = {
        let mut h = hub.lock().unwrap();
        h.next += 1;
        let id = h.next;
        h.sessions.insert(id, tx);
        h.clear_gesture();
        h.status = Status {
            connected: true,
            ..Status::default()
        };
        id
    };
    (Registration { hub, id }, rx)
}
/// Best-effort authenticated notice before local erasure. Local revocation
/// proceeds even if the peer is offline or the notice cannot be confirmed.
#[allow(dead_code)] // Called by the tray; the CLI includes this shared module.
pub async fn notify_revocation(hub: &Arc<Mutex<Hub>>, device: &str) -> bool {
    let receive = {
        let mut h = hub.lock().unwrap();
        if h.sessions.is_empty() || h.revocations.len() >= 4 {
            return false;
        }
        let (reply, receive) = oneshot::channel();
        h.revocations.insert(device.to_owned(), reply);
        receive
    };
    let result = tokio::time::timeout(Duration::from_millis(1500), receive)
        .await
        .is_ok_and(|result| result == Ok(true));
    hub.lock().unwrap().revocations.remove(device);
    result
}
pub async fn toggle(hub: &Arc<Mutex<Hub>>) -> Result<()> {
    let tx = {
        let h = hub.lock().unwrap();
        ensure!(
            h.sessions.len() == 1,
            "need exactly one connected phone session"
        );
        ensure!(
            h.status.capture.is_some() && h.status.capture != Some(CaptureState::Off),
            "Tap the phone to start its microphone"
        );
        h.sessions.values().next().unwrap().clone()
    };
    let (reply, receive) = oneshot::channel();
    tx.try_send(Toggle {
        expires: tokio::time::Instant::now() + Duration::from_secs(2),
        reply,
    })
    .map_err(|_| anyhow::anyhow!("capture request busy"))?;
    ensure!(
        tokio::time::timeout(Duration::from_secs(3), receive).await??,
        "phone state unknown, request expired or phone refused"
    );
    Ok(())
}
/// Same 300/500 ms classifier as Core.CaptureTrigger. It produces intent only.
#[derive(Default)]
pub struct CaptureTrigger {
    capture: u8,
    pressed: Option<u64>,
    previous_release: Option<u64>,
    last: u64,
    began_locked: bool,
}
impl CaptureTrigger {
    pub fn feed(&mut self, event: &str, time: u64) -> u8 {
        if event == "cancel" {
            *self = Self::default();
            return 0;
        }
        if time < self.last
            || (event == "press" && self.pressed.is_some())
            || (event == "release" && self.pressed.is_none())
        {
            return self.capture;
        }
        self.last = time;
        match event {
            "press" if self.pressed.is_none() => {
                self.pressed = Some(time);
                self.began_locked = self.capture == 2;
            }
            "advance" if self.pressed.is_some_and(|start| time - start >= 300) => {
                self.previous_release = None;
                self.capture = 1;
            }
            "release" => {
                if let Some(start) = self.pressed.take() {
                    if time - start >= 300 {
                        self.capture = 0;
                        self.previous_release = None;
                    } else if self.began_locked {
                        self.previous_release = None;
                    } else if self
                        .previous_release
                        .is_some_and(|previous| start - previous <= 500)
                    {
                        self.capture = 2;
                        self.previous_release = None;
                    } else {
                        self.capture = 0;
                        self.previous_release = Some(time);
                    }
                }
            }
            _ => {}
        }
        self.capture
    }
}
/// GUI edges share the classifier, but never acquire peer mic-start authority.
#[allow(dead_code)]
pub async fn gesture(hub: &Arc<Mutex<Hub>>, event: &str, milliseconds: u64) -> Result<String> {
    ensure!(
        ["press", "advance", "release", "cancel"].contains(&event),
        "invalid gesture"
    );
    let (after, released_hold) = {
        let mut h = hub.lock().unwrap();
        let context = (h.next, h.status.mode.clone(), h.snapshot().capture);
        if h.gesture_context.as_ref() != Some(&context) {
            h.gesture = CaptureTrigger::default();
            h.gesture_context = Some(context);
        }
        let released_hold = event == "release"
            && h.gesture.pressed.is_some_and(|start| {
                milliseconds
                    .checked_sub(start)
                    .is_some_and(|duration| duration >= 300)
            });
        let after = h.gesture.feed(event, milliseconds);
        (after, released_hold)
    };
    if after != 0 {
        return Ok("Tap the phone to start its microphone".into());
    }
    if released_hold {
        toggle(hub).await?;
        return Ok("Phone confirmed stop".into());
    }
    Ok("Single short tap: no capture".into())
}
#[allow(dead_code)] // Used by the GUI; CLI has a clap default.
pub fn default_state_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("VOICEREMOTE_STATE_DIR") {
        return path.into();
    }
    if cfg!(windows) {
        return std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join("voiceremote");
    }
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(std::env::temp_dir)
                .join(".local/state")
        })
        .join("voiceremote")
}
async fn exchange<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
    mut stream: S,
    hub: &Arc<Mutex<Hub>>,
) -> Result<()> {
    let mut request = [0; 7];
    tokio::time::timeout(Duration::from_secs(1), stream.read_exact(&mut request)).await??;
    // One fixed request; no JSON, text payloads, or unbounded allocation.
    let ok = request == *b"toggle\n" && toggle(hub).await.is_ok();
    stream
        .write_all(if ok { b"sent\n" } else { b"deny\n" })
        .await?;
    Ok(())
}
async fn request<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
    mut stream: S,
) -> Result<()> {
    stream.write_all(b"toggle\n").await?;
    let mut response = [0; 5];
    stream.read_exact(&mut response).await?;
    ensure!(
        &response == b"sent\n",
        "Stop unavailable or refused. Tap the phone to start its microphone"
    );
    Ok(())
}
#[cfg(unix)]
mod platform {
    use super::*;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use tokio::net::{UnixListener, UnixStream};
    fn uid() -> u32 {
        rustix::process::geteuid().as_raw()
    }
    pub fn same_user(actual: u32, expected: u32) -> Result<()> {
        ensure!(actual == expected, "local peer belongs to another user");
        Ok(())
    }
    fn directory(root: &Path) -> Result<()> {
        let meta = std::fs::symlink_metadata(root)?;
        ensure!(
            meta.is_dir()
                && !meta.file_type().is_symlink()
                && meta.permissions().mode() & 0o077 == 0,
            "local control directory must be private"
        );
        same_user(meta.uid(), uid())
    }
    pub async fn serve(root: &Path, hub: Arc<Mutex<Hub>>) -> Result<()> {
        directory(root)?;
        let path = root.join("control.sock");
        // Caller holds ReceiverLease, so a stale socket can be removed safely.
        if let Ok(meta) = std::fs::symlink_metadata(&path) {
            use std::os::unix::fs::FileTypeExt;
            ensure!(meta.file_type().is_socket(), "unsafe local control path");
            std::fs::remove_file(&path)?;
        }
        let listener = UnixListener::bind(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        loop {
            let (stream, _) = listener.accept().await?;
            if same_user(stream.peer_cred()?.uid(), uid()).is_err() {
                continue;
            }
            // Sequential with a deadline bounds resources from misbehaving clients.
            let _ = tokio::time::timeout(Duration::from_secs(4), exchange(stream, &hub)).await;
        }
    }
    pub async fn send(root: &Path) -> Result<()> {
        directory(root)?;
        let stream = UnixStream::connect(root.join("control.sock")).await?;
        same_user(stream.peer_cred()?.uid(), uid())?;
        request(stream).await
    }
}
#[cfg(windows)]
mod platform {
    use super::*;
    use sha2::{Digest, Sha256};
    use tokio::net::windows::named_pipe::{ClientOptions, ServerOptions};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, LocalFree},
        Security::Authorization::{
            ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        },
        Security::{GetTokenInformation, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser},
        System::{
            Pipes::GetNamedPipeServerProcessId,
            Threading::{
                GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
            },
        },
    };
    fn sid(process: windows_sys::Win32::Foundation::HANDLE) -> Result<String> {
        unsafe {
            let mut token = std::ptr::null_mut();
            ensure!(
                OpenProcessToken(process, TOKEN_QUERY, &mut token) != 0,
                "cannot query local user"
            );
            let result = (|| {
                let mut size = 0;
                GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut size);
                let mut buffer =
                    vec![0usize; (size as usize).div_ceil(std::mem::size_of::<usize>())];
                ensure!(
                    GetTokenInformation(
                        token,
                        TokenUser,
                        buffer.as_mut_ptr().cast(),
                        size,
                        &mut size
                    ) != 0,
                    "cannot read local user"
                );
                let user = &*(buffer.as_ptr().cast::<TOKEN_USER>());
                let mut value = std::ptr::null_mut();
                ensure!(
                    ConvertSidToStringSidW(user.User.Sid, &mut value) != 0,
                    "cannot format local user"
                );
                let mut len = 0;
                while *value.add(len) != 0 {
                    len += 1;
                }
                let text = String::from_utf16_lossy(std::slice::from_raw_parts(value, len));
                LocalFree(value.cast());
                Ok(text)
            })();
            CloseHandle(token);
            result
        }
    }
    fn name(root: &Path) -> Result<String> {
        let user = sid(unsafe { GetCurrentProcess() })?;
        let canonical = std::fs::canonicalize(root)?;
        let hash = Sha256::digest(canonical.to_string_lossy().as_bytes());
        Ok(format!(r"\\.\pipe\voiceremote-{user}-{:x}", hash))
    }
    fn create_server(
        name: &str,
        user: &str,
    ) -> Result<tokio::net::windows::named_pipe::NamedPipeServer> {
        // Protected DACL grants only this concrete user's SID. No inherited ACEs.
        let sddl: Vec<u16> = format!("D:P(A;;GA;;;{user})\0").encode_utf16().collect();
        let mut descriptor = std::ptr::null_mut();
        unsafe {
            ensure!(
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    1,
                    &mut descriptor,
                    std::ptr::null_mut()
                ) != 0,
                "cannot secure control pipe"
            );
        }
        let mut attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        let result = unsafe {
            ServerOptions::new()
                .first_pipe_instance(true)
                .reject_remote_clients(true)
                .create_with_security_attributes_raw(
                    name,
                    (&mut attributes as *mut SECURITY_ATTRIBUTES).cast(),
                )
        };
        unsafe {
            LocalFree(descriptor);
        }
        Ok(result?)
    }
    pub async fn serve(root: &Path, hub: Arc<Mutex<Hub>>) -> Result<()> {
        let name = name(root)?;
        let user = sid(unsafe { GetCurrentProcess() })?;
        let mut server = create_server(&name, &user)?;
        loop {
            server.connect().await?;
            let _ = tokio::time::timeout(Duration::from_secs(4), exchange(&mut server, &hub)).await;
            server.disconnect()?;
        }
    }
    pub async fn send(root: &Path) -> Result<()> {
        use std::os::windows::io::AsRawHandle;
        let stream = ClientOptions::new().open(name(root)?)?;
        // Check the server too: another user cannot squat on a predictable name.
        unsafe {
            let mut pid = 0;
            ensure!(
                GetNamedPipeServerProcessId(stream.as_raw_handle(), &mut pid) != 0,
                "cannot identify control server"
            );
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            ensure!(!process.is_null(), "cannot query control server");
            let actual = sid(process);
            CloseHandle(process);
            ensure!(
                actual? == sid(GetCurrentProcess())?,
                "control server belongs to another user"
            );
        }
        request(stream).await
    }
}
pub async fn serve(root: &Path, hub: Arc<Mutex<Hub>>) -> Result<()> {
    platform::serve(root, hub).await
}
pub async fn send(root: &Path) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(5), platform::send(root)).await??;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn phone_remote_desktop_timed_traces_match() {
        for (events, expected) in [
            (vec![("press", 0), ("release", 299)], vec![0, 0]),
            (
                vec![("press", 0), ("advance", 300), ("release", 300)],
                vec![0, 1, 0],
            ),
            (
                vec![
                    ("press", 0),
                    ("release", 20),
                    ("press", 520),
                    ("release", 540),
                ],
                vec![0, 0, 0, 2],
            ),
            (
                vec![
                    ("press", 0),
                    ("release", 20),
                    ("press", 521),
                    ("release", 540),
                ],
                vec![0, 0, 0, 0],
            ),
            (
                vec![
                    ("press", 0),
                    ("release", 20),
                    ("press", 50),
                    ("advance", 350),
                    ("release", 350),
                    ("press", 400),
                    ("release", 420),
                ],
                vec![0, 0, 0, 1, 0, 0, 0],
            ),
        ] {
            let mut trigger = CaptureTrigger::default();
            assert_eq!(
                events
                    .iter()
                    .map(|(event, time)| trigger.feed(event, *time))
                    .collect::<Vec<_>>(),
                expected
            );
            assert_eq!(trigger.feed("cancel", 0), 0);
        }
    }
    #[tokio::test]
    async fn off_phone_requires_phone_tap_and_never_enqueues_start() {
        let hub = Arc::new(Mutex::new(Hub::default()));
        let (_registration, mut rx) = register(hub.clone());
        hub.lock().unwrap().status.capture = Some(CaptureState::Off);
        assert!(
            toggle(&hub)
                .await
                .unwrap_err()
                .to_string()
                .contains("Tap the phone")
        );
        for (event, time) in [
            ("press", 0),
            ("release", 20),
            ("press", 40),
            ("release", 60),
        ] {
            let _ = gesture(&hub, event, time).await.unwrap();
        }
        assert!(rx.try_recv().is_err());
    }
    #[tokio::test]
    async fn batch_delayed_hold_release_still_sends_only_stop() {
        let hub = Arc::new(Mutex::new(Hub::default()));
        let (_registration, mut rx) = register(hub.clone());
        hub.lock().unwrap().status.capture = Some(CaptureState::Continuous);
        gesture(&hub, "press", 0).await.unwrap();
        let copy = hub.clone();
        let release = tokio::spawn(async move { gesture(&copy, "release", 300).await });
        let request = tokio::time::timeout(Duration::from_millis(100), rx.recv())
            .await
            .expect("hold release must request stop even without timer delivery")
            .unwrap();
        request.reply.send(true).unwrap();
        assert_eq!(release.await.unwrap().unwrap(), "Phone confirmed stop");
    }
    #[tokio::test]
    async fn reconnect_mode_and_off_clear_pending_double_tap() {
        let hub = Arc::new(Mutex::new(Hub::default()));
        let (registration, _rx) = register(hub.clone());
        hub.lock().unwrap().status.capture = Some(CaptureState::Off);
        for (event, time) in [("press", 0), ("release", 20)] {
            gesture(&hub, event, time).await.unwrap();
        }
        hub.lock().unwrap().clear_gesture(); // same hook used by mode/OFF reports
        for (event, time) in [("press", 40), ("release", 60)] {
            gesture(&hub, event, time).await.unwrap();
        }
        assert_eq!(hub.lock().unwrap().gesture.capture, 0);
        drop(registration);
        let (_new, _rx) = register(hub.clone());
        hub.lock().unwrap().status.capture = Some(CaptureState::Off);
        for (event, time) in [("press", 70), ("release", 90)] {
            gesture(&hub, event, time).await.unwrap();
        }
        assert_eq!(hub.lock().unwrap().gesture.capture, 0);
    }
    #[test]
    fn disconnected_or_ambiguous_sessions_never_show_stale_phone_state() {
        let hub = Arc::new(Mutex::new(Hub::default()));
        let (first, _rx) = register(hub.clone());
        hub.lock().unwrap().status.capture = Some(CaptureState::Continuous);
        assert_eq!(
            hub.lock().unwrap().snapshot().capture,
            Some(CaptureState::Continuous)
        );
        let (second, _rx) = register(hub.clone());
        assert!(hub.lock().unwrap().snapshot().capture.is_none());
        drop(second);
        assert!(hub.lock().unwrap().snapshot().capture.is_none());
        drop(first);
        assert!(!hub.lock().unwrap().snapshot().connected);
    }
    #[tokio::test]
    async fn disconnected_and_ambiguous_sessions_refuse_toggle() {
        let hub = Arc::new(Mutex::new(Hub::default()));
        assert!(toggle(&hub).await.is_err());
        let (_a, _rx) = register(hub.clone());
        let (_b, _rx) = register(hub.clone());
        assert!(toggle(&hub).await.is_err());
    }
    #[cfg(windows)]
    #[tokio::test]
    async fn local_pipe_delivers_request_to_current_user() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let hub = Arc::new(Mutex::new(Hub::default()));
        let (_registration, mut rx) = register(hub.clone());
        hub.lock().unwrap().status.capture = Some(CaptureState::Continuous);
        let path = dir.path().to_owned();
        let task = tokio::spawn(async move { serve(&path, hub).await });
        let phone = tokio::spawn(async move {
            rx.recv().await.unwrap().reply.send(true).unwrap();
        });
        let mut delivered = false;
        for _ in 0..100 {
            if send(dir.path()).await.is_ok() {
                delivered = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(delivered, "current user's named pipe must deliver");
        phone.await?;
        task.abort();
        Ok(())
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn local_socket_delivers_request_and_rejects_other_uid_and_public_directory() -> Result<()>
    {
        use std::os::unix::fs::PermissionsExt;
        assert!(platform::same_user(1001, 1000).is_err());
        let dir = tempfile::tempdir()?;
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700))?;
        let hub = Arc::new(Mutex::new(Hub::default()));
        let (_registration, mut rx) = register(hub.clone());
        hub.lock().unwrap().status.capture = Some(CaptureState::Continuous);
        let path = dir.path().to_owned();
        let task = tokio::spawn(async move { serve(&path, hub).await });
        for _ in 0..100 {
            if dir.path().join("control.sock").exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let phone = tokio::spawn(async move {
            rx.recv().await.unwrap().reply.send(true).unwrap();
        });
        send(dir.path()).await?;
        phone.await?;
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o755))?;
        assert!(send(dir.path()).await.is_err());
        task.abort();
        Ok(())
    }
}
