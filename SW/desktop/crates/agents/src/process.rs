//! Bounded subprocess execution. Transcript bytes never enter argv or diagnostics.
use crate::registry::{Provider, SessionIdentity};
#[cfg(any(unix, windows, test))]
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
#[cfg(any(unix, windows))]
use serde_json::Value;
#[cfg(any(unix, windows))]
use std::process::{ExitStatus, Stdio};
use std::{collections::BTreeMap, ffi::OsString, time::Duration};
use tokio::sync::watch;
#[cfg(any(unix, windows))]
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    process::Command,
};

#[derive(Clone)]
pub struct CliAdapter {
    environment: BTreeMap<OsString, OsString>,
}
impl voiceremote_core::AgentAdapter for CliAdapter {}
impl Default for CliAdapter {
    fn default() -> Self {
        // Auth is left to the installed CLI's own credential store. No API keys,
        // cloud credentials, relay secrets, loader overrides or proxy env inherit.
        #[allow(unused_mut)]
        let mut environment: BTreeMap<OsString, OsString> = [
            "PATH",
            "PATHEXT",
            "HOME",
            "USERPROFILE",
            "LOCALAPPDATA",
            "APPDATA",
            "SystemRoot",
            "LANG",
            "LC_ALL",
            "TMPDIR",
            "TEMP",
            "TMP",
            "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS",
        ]
        .into_iter()
        .filter_map(|key| std::env::var_os(key).map(|v| (key.into(), v)))
        .collect();
        #[cfg(windows)]
        environment
            .entry("PATHEXT".into())
            .or_insert_with(|| ".COM;.EXE;.BAT;.CMD".into());
        Self { environment }
    }
}
impl CliAdapter {
    fn executable(&self, name: &str) -> OsString {
        #[cfg(windows)]
        if let Some(path) = self.environment.get(std::ffi::OsStr::new("PATH")) {
            // Native installs and npm's installed command shim are supported.
            // Prompt bytes stay on stdin; session IDs and all argv flags are closed.
            for directory in std::env::split_paths(path) {
                for extension in ["exe", "cmd"] {
                    let file = directory.join(format!("{name}.{extension}"));
                    if file.is_file() {
                        return file.into_os_string();
                    }
                }
            }
        }
        name.into()
    }
    /// Trusted launcher environment (same allowlist as Default); useful for fake CLIs.
    pub fn with_path(path: OsString) -> Self {
        let mut adapter = Self::default();
        adapter.environment.insert("PATH".into(), path);
        adapter
    }
}
#[cfg(windows)]
fn command_directory(
    executable: &std::ffi::OsStr,
    workspace: &std::path::Path,
) -> Result<std::path::PathBuf> {
    use std::path::{Component, Prefix};
    if !std::path::Path::new(executable)
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("cmd"))
    {
        return Ok(workspace.to_owned());
    }
    let mut components = workspace.components();
    let Some(Component::Prefix(prefix)) = components.next() else {
        anyhow::bail!("shim needs absolute workspace")
    };
    let directory = match prefix.kind() {
        Prefix::VerbatimDisk(drive) => {
            let mut path = std::path::PathBuf::from(format!("{}:\\", drive as char));
            for component in components {
                if let Component::Normal(part) = component {
                    path.push(part);
                }
            }
            path
        }
        Prefix::Disk(_) => workspace.to_owned(),
        _ => anyhow::bail!("cmd shim cannot use UNC workspace; install a native CLI"),
    };
    ensure!(
        directory.as_os_str().len() < 260
            && directory.canonicalize()? == workspace.canonicalize()?,
        "cmd workspace is not representable"
    );
    Ok(directory)
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Finish {
    Completed,
    Pending,
    SpawnFailed,
    IoFailed,
    TimedOut,
    Cancelled,
    Unconfirmed,
    OutputLimit,
    InvalidOutput,
    NotConfigured,
    UnsupportedPlatform,
    UnsupportedAction,
    CloudSubmitted,
    CloudFailed,
    CancelUnsupported,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessResult {
    /// Ephemeral provider response; durable replay receipts never retain content.
    #[serde(skip)]
    pub app_reply: Option<String>,
    pub finish: Finish,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub success: bool,
    #[serde(default)]
    pub termination_confirmed: bool,
    #[serde(default)]
    pub scope_unit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloud: Option<crate::CloudReceipt>,
}
impl ProcessResult {
    pub(crate) fn no_process(finish: Finish) -> Self {
        Self {
            app_reply: None,
            finish,
            exit_code: None,
            signal: None,
            success: false,
            termination_confirmed: true,
            scope_unit: None,
            cloud: None,
        }
    }
}
#[cfg(unix)]
struct ProcessTree {
    pid: i32,
    unit: Option<String>,
    environment: BTreeMap<OsString, OsString>,
    armed: bool,
}
#[cfg(unix)]
impl Drop for ProcessTree {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        unsafe {
            libc::kill(-self.pid, libc::SIGKILL);
        }
        if let Some(unit) = self.unit.clone() {
            let environment = self.environment.clone();
            // Emergency cleanup if the runtime drops a worker. A durable running
            // receipt remains; this path never claims confirmed cancellation.
            std::thread::spawn(move || {
                for args in [
                    vec!["--user", "kill", "--kill-whom=all", "--signal=KILL", &unit],
                    vec!["--user", "stop", "--no-block", &unit],
                ] {
                    let _ = std::process::Command::new("systemctl")
                        .args(args)
                        .env_clear()
                        .envs(&environment)
                        .stdin(Stdio::null())
                        .stdout(Stdio::null())
                        .stderr(Stdio::null())
                        .status();
                }
            });
        }
    }
}
#[cfg(any(unix, windows))]
impl CliAdapter {
    pub(crate) async fn cloud_capture(
        &self,
        executable: &str,
        args: &[&str],
        session: &SessionIdentity,
        limit: usize,
    ) -> Option<(bool, Vec<u8>)> {
        let resolved = self.executable(executable);
        #[cfg(windows)]
        let directory = command_directory(&resolved, &session.workspace).ok()?;
        #[cfg(not(windows))]
        let directory = &session.workspace;
        let mut command = Command::new(resolved);
        command
            .args(args)
            .current_dir(directory)
            .env_clear()
            .envs(&self.environment)
            .env("NO_COLOR", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        #[cfg(windows)]
        command.creation_flags(4);
        tokio::time::timeout(Duration::from_secs(2), async {
            #[cfg(windows)]
            let job = crate::windows_job::Job::new().ok()?;
            let mut child = command.spawn().ok()?;
            #[cfg(windows)]
            if job
                .assign_and_resume(child.raw_handle()?, child.id()?)
                .is_err()
            {
                let _ = child.kill().await;
                return None;
            }
            let stdout = child.stdout.take()?;
            let (out, status) = tokio::try_join!(bounded(stdout, limit), async {
                child.wait().await.map_err(anyhow::Error::from)
            })
            .ok()?;
            #[cfg(windows)]
            if !job.terminate().await {
                return None;
            }
            Some((status.success(), out))
        })
        .await
        .ok()?
    }
    #[cfg(unix)]
    async fn control(&self, args: &[&str]) -> Option<std::process::Output> {
        let mut command = Command::new("systemctl");
        command
            .args(args)
            .env_clear()
            .envs(&self.environment)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        tokio::time::timeout(Duration::from_secs(2), async {
            let mut child = command.spawn().ok()?;
            let output = child.stdout.take()?;
            let (stdout, status) = tokio::try_join!(bounded(output, 4096), async {
                child.wait().await.map_err(anyhow::Error::from)
            })
            .ok()?;
            Some(std::process::Output {
                status,
                stdout,
                stderr: vec![],
            })
        })
        .await
        .ok()?
    }

    #[cfg(unix)]
    async fn user_bus(&self) -> bool {
        self.control(&["--user", "show", "--property=Version", "--value"])
            .await
            .is_some_and(|o| o.status.success())
    }
    #[cfg(unix)]
    async fn stop_scope(&self, unit: &str) -> bool {
        let _ = self
            .control(&["--user", "kill", "--kill-whom=all", "--signal=KILL", unit])
            .await;
        let _ = self.control(&["--user", "stop", unit]).await;
        self.control(&[
            "--user",
            "show",
            "--property=ActiveState",
            "--property=TasksCurrent",
            "--property=LoadState",
            unit,
        ])
        .await
        .is_some_and(|o| {
            if !o.status.success() {
                return false;
            }
            let text = std::str::from_utf8(&o.stdout).unwrap_or("");
            let property = |name: &str| text.lines().find_map(|line| line.strip_prefix(name));
            matches!(property("ActiveState="), Some("inactive" | "failed"))
                && (property("TasksCurrent=") == Some("0")
                    || property("LoadState=") == Some("not-found"))
        })
    }
}
#[cfg(any(unix, windows))]
async fn bounded(input: impl AsyncRead + Unpin, limit: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    input.take(limit as u64 + 1).read_to_end(&mut bytes).await?;
    ensure!(bytes.len() <= limit, "output bound");
    Ok(bytes)
}
#[cfg(any(unix, windows))]
fn structured_success(provider: Provider, bytes: &[u8], session: &str) -> bool {
    match provider {
        Provider::Claude => serde_json::from_slice::<Value>(bytes).is_ok_and(|v| {
            v["type"] == "result"
                && v["subtype"] == "success"
                && v["is_error"] == false
                && v["session_id"] == session
        }),
        Provider::Codex => {
            let Ok(text) = std::str::from_utf8(bytes) else {
                return false;
            };
            let mut identity = false;
            let mut complete = false;
            for line in text.lines().filter(|s| !s.trim().is_empty()) {
                let Ok(event) = serde_json::from_str::<Value>(line) else {
                    return false;
                };
                match event["type"].as_str() {
                    Some("thread.started") => {
                        if event["thread_id"] != session {
                            return false;
                        }
                        identity = true;
                    }
                    Some("turn.completed") => complete = true,
                    Some("turn.failed") => return false,
                    // `error` may be a recoverable stream/reconnect warning.
                    // A matching thread, completed turn AND exit zero are required.
                    Some("error") => {}
                    _ => {}
                }
            }
            identity && complete
        }
        Provider::Cloud => false,
    }
}
#[cfg(any(unix, windows))]
fn structured_reply(provider: Provider, bytes: &[u8]) -> Option<String> {
    let reply = match provider {
        Provider::Claude => serde_json::from_slice::<Value>(bytes).ok()?["result"]
            .as_str()?
            .to_owned(),
        Provider::Codex => std::str::from_utf8(bytes)
            .ok()?
            .lines()
            .filter_map(|line| {
                let value: Value = serde_json::from_str(line).ok()?;
                (value["type"] == "item.completed" && value["item"]["type"] == "agent_message")
                    .then(|| value["item"]["text"].as_str().map(str::to_owned))
                    .flatten()
            })
            .last()?,
        Provider::Cloud => return None,
    };
    Some(reply.chars().take(4096).collect())
}
impl CliAdapter {
    pub(crate) async fn run(
        &self,
        session: &SessionIdentity,
        instruction: &str,
        timeout: Duration,
        output_limit: usize,
        cancel: watch::Receiver<bool>,
    ) -> ProcessResult {
        let cloud = session.provider == Provider::Cloud;
        if cloud && !session.cloud.as_ref().is_some_and(|c| c.enabled) {
            return crate::cloud::result(session, Finish::NotConfigured);
        }
        if cloud
            && session.capability_profile == crate::CapabilityProfile::ReadOnly
            && !session
                .cloud
                .as_ref()
                .is_some_and(|c| c.allow_read_only_override)
        {
            return crate::cloud::result(session, Finish::UnsupportedAction);
        }
        // Other platforms fail closed before spawning.
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (instruction, timeout, output_limit, cancel);
            return if cloud {
                crate::cloud::result(session, Finish::UnsupportedPlatform)
            } else {
                ProcessResult::no_process(Finish::UnsupportedPlatform)
            };
        }
        #[cfg(any(unix, windows))]
        {
            let executable = match session.provider {
                Provider::Claude => "claude",
                Provider::Codex => "codex",
                Provider::Cloud => match session.cloud.as_ref().unwrap().provider {
                    crate::CloudProvider::Codex => "codex",
                    crate::CloudProvider::Claude => "claude",
                },
            };
            if *cancel.borrow() {
                return if cloud {
                    crate::cloud::result(session, Finish::Cancelled)
                } else {
                    ProcessResult::no_process(Finish::Cancelled)
                };
            }
            if cloud && !self.cloud_repository(session).await {
                return crate::cloud::result(session, Finish::NotConfigured);
            }
            #[cfg(unix)]
            let has_bus = self.user_bus().await;
            #[cfg(windows)]
            let has_bus = false;
            if *cancel.borrow() {
                return if cloud {
                    crate::cloud::result(session, Finish::Cancelled)
                } else {
                    ProcessResult::no_process(Finish::Cancelled)
                };
            }
            let unit = if has_bus {
                static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
                Some(format!(
                    "voiceremote-task-{}-{}-{}.scope",
                    std::process::id(),
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_nanos(),
                    NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                ))
            } else {
                None
            };
            let resolved = self.executable(executable);
            #[cfg(windows)]
            let directory = match command_directory(&resolved, &session.workspace) {
                Ok(directory) => directory,
                Err(_) => return ProcessResult::no_process(Finish::UnsupportedPlatform),
            };
            #[cfg(not(windows))]
            let directory = &session.workspace;
            let mut command = if let Some(unit) = &unit {
                let mut command = Command::new("systemd-run");
                command.arg(format!(
                    "--property=RuntimeMaxSec={}s",
                    timeout.as_secs().saturating_add(10)
                ));
                command.args([
                    "--user",
                    "--scope",
                    "--quiet",
                    "--expand-environment=no",
                    "--unit",
                    unit,
                    "--property=KillMode=control-group",
                    "--property=TasksAccounting=yes",
                    "--property=MemoryMax=2G",
                    "--property=CPUQuota=100%",
                    "--",
                    executable,
                ]);
                command
            } else {
                Command::new(resolved)
            };
            match session.provider {
                Provider::Claude => {
                    command.args([
                        "-p",
                        "--resume",
                        &session.provider_session_id,
                        "--output-format",
                        "json",
                    ]);
                    command.args([
                        "--tools",
                        if session.capability_profile == crate::CapabilityProfile::ReadOnly {
                            "Read,Glob,Grep"
                        } else {
                            "Read,Glob,Grep,Edit,Write"
                        },
                        "--restricted",
                        "--strict-mcp-config",
                        "--disable-slash-commands",
                        "--settings",
                        r#"{"disableAllHooks":true}"#,
                    ]);
                }
                Provider::Codex => {
                    command.args([
                        "-a",
                        "never",
                        "exec",
                        "-s",
                        session.capability_profile.sandbox(),
                        "resume",
                        "--json",
                        &session.provider_session_id,
                        "-",
                    ]);
                }
                Provider::Cloud => {
                    let config = session.cloud.as_ref().unwrap();
                    match config.provider {
                        crate::CloudProvider::Codex => {
                            command.args([
                                "cloud",
                                "exec",
                                "--env",
                                &config.environment,
                                "--branch",
                                &config.branch,
                                "--attempts",
                                "1",
                                "-",
                            ]);
                        }
                        crate::CloudProvider::Claude => {
                            command.args(["--cloud", "--environment", &config.environment, "-p"]);
                        }
                    }
                }
            }
            command
                .current_dir(directory)
                .env_clear()
                .envs(&self.environment)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true);
            #[cfg(unix)]
            command.process_group(0);
            #[cfg(windows)]
            command.creation_flags(4); // CREATE_SUSPENDED
            #[cfg(windows)]
            let job = match crate::windows_job::Job::new() {
                Ok(job) => job,
                Err(_) => return ProcessResult::no_process(Finish::SpawnFailed),
            };
            let Ok(mut child) = command.spawn() else {
                return if cloud {
                    crate::cloud::result(session, Finish::SpawnFailed)
                } else {
                    ProcessResult::no_process(Finish::SpawnFailed)
                };
            };
            #[cfg(windows)]
            if job
                .assign_and_resume(child.raw_handle().unwrap(), child.id().unwrap())
                .is_err()
            {
                let _ = child.kill().await;
                return ProcessResult::no_process(Finish::SpawnFailed);
            }
            #[cfg(unix)]
            let mut tree = ProcessTree {
                pid: child.id().expect("fresh process") as i32,
                unit: unit.clone(),
                environment: self.environment.clone(),
                armed: true,
            };
            let stdin = child.stdin.take().unwrap();
            let stdout = child.stdout.take().unwrap();
            let stderr = child.stderr.take().unwrap();
            // Include stdin writes and pipe drains in the deadline, so a child
            // that never reads input or whose descendants retain pipes is bounded.
            let work = async {
                let write = async {
                    let mut stdin = stdin;
                    stdin.write_all(instruction.as_bytes()).await?;
                    stdin.shutdown().await
                };
                let ((), out, _err, status) = tokio::try_join!(
                    async { write.await.map_err(anyhow::Error::from) },
                    bounded(stdout, output_limit),
                    bounded(stderr, output_limit),
                    async { child.wait().await.map_err(anyhow::Error::from) }
                )?;
                Ok::<(Vec<u8>, ExitStatus), anyhow::Error>((out, status))
            };
            let result = tokio::select! {
                biased;
                _=crate::receiver::stopped(cancel.clone()) => Err(Finish::Cancelled),
                _=tokio::time::sleep(timeout) => Err(Finish::TimedOut),
                value=work => value.map_err(|error| if error.to_string() == "output bound" { Finish::OutputLimit } else { Finish::IoFailed }),
            };
            // A process group is only best effort: real tool processes can
            // setsid/setpgid. Only an inactive systemd scope confirms cleanup.
            #[cfg(unix)]
            unsafe {
                libc::kill(-tree.pid, libc::SIGKILL);
            }
            #[cfg(unix)]
            let termination_confirmed = if let Some(unit) = &unit {
                self.stop_scope(unit).await
            } else {
                false
            };
            #[cfg(unix)]
            {
                tree.armed = false;
            }
            #[cfg(windows)]
            let termination_confirmed = job.terminate().await;
            match result {
                Ok((out, status)) => {
                    if cloud {
                        let mut result = crate::cloud::submitted(session, &out, status.success());
                        result.exit_code = status.code();
                        result.signal = exit_signal(&status);
                        result.termination_confirmed = termination_confirmed;
                        result.scope_unit = unit;
                        if result.finish == Finish::CloudSubmitted {
                            self.cloud_snapshot(
                                session,
                                result.cloud.as_mut().unwrap(),
                                output_limit,
                            )
                            .await;
                            if result.cloud.as_ref().unwrap().state == crate::CloudState::Failed {
                                result.finish = Finish::CloudFailed;
                            }
                        }
                        return result;
                    }
                    let valid =
                        structured_success(session.provider, &out, &session.provider_session_id);
                    let unconfirmed = !termination_confirmed;
                    ProcessResult {
                        app_reply: if valid {
                            structured_reply(session.provider, &out)
                        } else {
                            None
                        },
                        finish: if unconfirmed {
                            Finish::Unconfirmed
                        } else if !status.success() || valid {
                            Finish::Completed
                        } else {
                            Finish::InvalidOutput
                        },
                        exit_code: status.code(),
                        signal: exit_signal(&status),
                        success: !unconfirmed && status.success() && valid,
                        termination_confirmed,
                        scope_unit: unit.clone(),
                        cloud: None,
                    }
                }
                Err(finish) => {
                    let status = tokio::time::timeout(Duration::from_secs(2), child.wait())
                        .await
                        .ok()
                        .and_then(Result::ok);

                    ProcessResult {
                        app_reply: None,
                        finish: if cloud {
                            Finish::Unconfirmed
                        } else if termination_confirmed {
                            finish
                        } else {
                            Finish::Unconfirmed
                        },
                        exit_code: status.as_ref().and_then(ExitStatus::code),
                        signal: status.as_ref().and_then(exit_signal),
                        success: false,
                        termination_confirmed,
                        scope_unit: unit.clone(),
                        cloud: if cloud {
                            crate::cloud::result(session, Finish::Unconfirmed).cloud
                        } else {
                            None
                        },
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(windows)]
    #[tokio::test]
    async fn npm_cmd_shim_preserves_workspace_stdin_and_native_resolution() -> Result<()> {
        let root = tempfile::tempdir()?;
        std::fs::write(
            root.path().join("claude.cmd"),
            r#"@echo off
set /p synthetic_input=
where cmd > native-resolution.txt
if errorlevel 1 exit /b 25
cd > launch-directory.txt
echo {"type":"result","subtype":"success","is_error":false,"session_id":"test-session","result":"Synthetic shim reply"}
"#,
        )?;
        let workspace = root.path().canonicalize()?; // Windows supplies a verbatim prefix.
        let paths = std::env::join_paths(std::iter::once(root.path().to_owned()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))?;
        let adapter = CliAdapter::with_path(paths);
        assert!(
            adapter
                .environment
                .get(std::ffi::OsStr::new("PATHEXT"))
                .is_some_and(|v| !v.is_empty())
        );
        let session = SessionIdentity {
            provider: Provider::Claude,
            account: "test".into(),
            host: "pc".into(),
            project: "test".into(),
            workspace: workspace.clone(),
            provider_session_id: "test-session".into(),
            capability_profile: crate::CapabilityProfile::ReadOnly,
            cloud: None,
        };
        let (_cancel, receive) = watch::channel(false);
        let result = adapter
            .run(
                &session,
                "Synthetic shim input",
                Duration::from_secs(10),
                4096,
                receive,
            )
            .await;
        assert_eq!(result.finish, Finish::Completed);
        assert!(result.success);
        assert_eq!(result.app_reply.as_deref(), Some("Synthetic shim reply"));
        let actual = std::fs::read_to_string(root.path().join("launch-directory.txt"))?;
        assert_eq!(
            std::path::Path::new(actual.trim()).canonicalize()?,
            workspace
        );
        assert!(
            !std::fs::read_to_string(root.path().join("native-resolution.txt"))?
                .trim()
                .is_empty()
        );
        assert!(
            command_directory(
                std::ffi::OsStr::new("claude.cmd"),
                std::path::Path::new(r"\\?\UNC\server\share\project")
            )
            .is_err()
        );
        Ok(())
    }
    /// Off by default. Requires explicit owner-selected existing Claude AND Codex
    /// sessions. Never prints their content, credential files or provider output.
    #[tokio::test]
    async fn live_cli_smoke_opt_in() -> Result<()> {
        if std::env::var("VOICEREMOTE_LIVE_AGENT_SMOKE").as_deref() != Ok("1") {
            return Ok(());
        }
        let path = std::env::var_os("VOICEREMOTE_LIVE_AGENT_CONFIG")
            .ok_or_else(|| anyhow::anyhow!("live config missing"))?;
        let config = crate::Allowlist::load(std::path::Path::new(&path))?;
        let sessions = config.sessions()?;
        for provider in [Provider::Claude, Provider::Codex] {
            let session = sessions
                .iter()
                .find(|s| s.provider == provider)
                .ok_or_else(|| anyhow::anyhow!("live provider session missing"))?;
            let (_send, receive) = watch::channel(false);
            let result = CliAdapter::default()
                .run(
                    session,
                    "Reply with OK only. Do not use tools or modify files.",
                    Duration::from_secs(60),
                    1024 * 1024,
                    receive,
                )
                .await;
            ensure!(
                result.success,
                "live smoke failed: {:?}, exit {:?}",
                result.finish,
                result.exit_code
            );
        }
        Ok(())
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn observed_nonzero_exit_survives_deadline_and_tree_cleanup() -> Result<()> {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir()?;
        let file = root.path().join("claude");
        // The leader exits 7 while a descendant keeps both output pipes open.
        // The pipe deadline then cancels work and runs cleanup; it must retain
        // the leader's observed status rather than substitute SIGKILL or None.
        std::fs::write(&file, "#!/bin/sh\nread input\n/bin/sleep 60 &\nexit 7\n")?;
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o700))?;
        let session = SessionIdentity {
            provider: Provider::Claude,
            account: "test".into(),
            host: "test".into(),
            project: "test".into(),
            workspace: root.path().to_path_buf(),
            provider_session_id: "test-session".into(),
            capability_profile: crate::CapabilityProfile::ReadOnly,
            cloud: None,
        };
        // No systemctl on this trusted PATH: exercise the real no-bus path.
        let adapter = CliAdapter::with_path(root.path().as_os_str().to_owned());
        let (_send, receive) = watch::channel(false);
        let result = adapter
            .run(
                &session,
                "synthetic\n",
                Duration::from_secs(3),
                1024,
                receive,
            )
            .await;
        assert_eq!(result.exit_code, Some(7));
        assert_eq!(result.signal, None);
        assert_eq!(result.finish, Finish::Unconfirmed);
        assert!(!result.success);
        assert!(!result.termination_confirmed);
        Ok(())
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn real_exit_code_and_timeout_signal_are_retained() -> Result<()> {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir()?;
        let file = root.path().join("claude");
        std::fs::write(
            &file,
            "#!/bin/sh\nread input\nif [ \"$input\" = wait ]; then exec sleep 60; fi\nexit 7\n",
        )?;
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o700))?;
        let session = SessionIdentity {
            provider: Provider::Claude,
            account: "test".into(),
            host: "test".into(),
            project: "test".into(),
            workspace: root.path().to_path_buf(),
            provider_session_id: "test-session".into(),
            capability_profile: crate::CapabilityProfile::ReadOnly,
            cloud: None,
        };
        let adapter =
            CliAdapter::with_path(format!("{}:/usr/bin:/bin", root.path().display()).into());
        let (_send, receive) = watch::channel(false);
        let result = adapter
            .run(
                &session,
                "synthetic\n",
                Duration::from_secs(1),
                1024,
                receive.clone(),
            )
            .await;
        assert_eq!(result.exit_code, Some(7));
        assert!(!result.success);
        let result = adapter
            .run(
                &session,
                "wait\n",
                Duration::from_millis(100),
                1024,
                receive,
            )
            .await;
        // A systemd user bus confirms cleanup; without one the same stop stays unconfirmed.
        if result.termination_confirmed {
            assert_eq!(result.finish, Finish::TimedOut);
        } else {
            assert_eq!(result.finish, Finish::Unconfirmed);
        }
        assert_eq!(result.signal, Some(9));
        assert!(!result.success);
        Ok(())
    }
}

#[cfg(any(unix, windows))]
fn exit_signal(status: &ExitStatus) -> Option<i32> {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        status.signal()
    }
    #[cfg(windows)]
    {
        let _ = status;
        None
    }
}
