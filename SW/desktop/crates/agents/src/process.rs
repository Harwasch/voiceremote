//! Bounded subprocess execution. Transcript bytes never enter argv or diagnostics.
use crate::registry::{Provider, SessionIdentity};
#[cfg(any(unix, test))]
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
#[cfg(unix)]
use serde_json::Value;
#[cfg(unix)]
use std::process::{ExitStatus, Stdio};
use std::{collections::BTreeMap, ffi::OsString, time::Duration};
use tokio::sync::watch;
#[cfg(unix)]
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
        let environment = [
            "PATH",
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
        Self { environment }
    }
}
impl CliAdapter {
    /// Trusted launcher environment (same allowlist as Default); useful for fake CLIs.
    pub fn with_path(path: OsString) -> Self {
        let mut adapter = Self::default();
        adapter.environment.insert("PATH".into(), path);
        adapter
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Finish {
    Completed,
    SpawnFailed,
    IoFailed,
    TimedOut,
    Cancelled,
    Unconfirmed,
    OutputLimit,
    InvalidOutput,
    NotConfigured,
    UnsupportedPlatform,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessResult {
    pub finish: Finish,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
    pub success: bool,
    #[serde(default)]
    pub termination_confirmed: bool,
    #[serde(default)]
    pub scope_unit: Option<String>,
}
impl ProcessResult {
    pub(crate) fn no_process(finish: Finish) -> Self {
        Self {
            finish,
            exit_code: None,
            signal: None,
            success: false,
            termination_confirmed: true,
            scope_unit: None,
        }
    }
}
/// Cloud implementations must return a real provider outcome, never pretend to resume local state.
pub trait CloudAdapter: voiceremote_core::AgentAdapter {
    fn unavailable(&self) -> ProcessResult;
}
pub struct UnconfiguredCloud;
impl voiceremote_core::AgentAdapter for UnconfiguredCloud {}
impl CloudAdapter for UnconfiguredCloud {
    fn unavailable(&self) -> ProcessResult {
        ProcessResult::no_process(Finish::NotConfigured)
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
#[cfg(unix)]
impl CliAdapter {
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

    async fn user_bus(&self) -> bool {
        self.control(&["--user", "show", "--property=Version", "--value"])
            .await
            .is_some_and(|o| o.status.success())
    }
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
#[cfg(unix)]
async fn bounded(input: impl AsyncRead + Unpin, limit: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    input.take(limit as u64 + 1).read_to_end(&mut bytes).await?;
    ensure!(bytes.len() <= limit, "output bound");
    Ok(bytes)
}
#[cfg(unix)]
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
impl CliAdapter {
    pub(crate) async fn run(
        &self,
        session: &SessionIdentity,
        instruction: &str,
        timeout: Duration,
        output_limit: usize,
        cancel: watch::Receiver<bool>,
    ) -> ProcessResult {
        if session.provider == Provider::Cloud {
            return UnconfiguredCloud.unavailable();
        }
        // The headless node in task 12 is Linux. Refuse rather than start an
        // uncontained Windows child until a suspended-start Job Object exists.
        #[cfg(not(unix))]
        {
            let _ = (instruction, timeout, output_limit, cancel);
            return ProcessResult::no_process(Finish::UnsupportedPlatform);
        }
        #[cfg(unix)]
        {
            let executable = match session.provider {
                Provider::Claude => "claude",
                Provider::Codex => "codex",
                Provider::Cloud => unreachable!(),
            };
            if *cancel.borrow() {
                return ProcessResult::no_process(Finish::Cancelled);
            }
            let has_bus = self.user_bus().await;
            if *cancel.borrow() {
                return ProcessResult::no_process(Finish::Cancelled);
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
                Command::new(executable)
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
                Provider::Cloud => unreachable!(),
            }
            command
                .current_dir(&session.workspace)
                .env_clear()
                .envs(&self.environment)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true);
            command.process_group(0);
            let Ok(mut child) = command.spawn() else {
                return ProcessResult::no_process(Finish::SpawnFailed);
            };
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
            unsafe {
                libc::kill(-tree.pid, libc::SIGKILL);
            }
            let termination_confirmed = if let Some(unit) = &unit {
                self.stop_scope(unit).await
            } else {
                false
            };
            tree.armed = false;
            match result {
                Ok((out, status)) => {
                    use std::os::unix::process::ExitStatusExt;
                    let valid =
                        structured_success(session.provider, &out, &session.provider_session_id);
                    let unconfirmed = !termination_confirmed;
                    ProcessResult {
                        finish: if unconfirmed {
                            Finish::Unconfirmed
                        } else if !status.success() || valid {
                            Finish::Completed
                        } else {
                            Finish::InvalidOutput
                        },
                        exit_code: status.code(),
                        signal: status.signal(),
                        success: !unconfirmed && status.success() && valid,
                        termination_confirmed,
                        scope_unit: unit.clone(),
                    }
                }
                Err(finish) => {
                    let status = tokio::time::timeout(Duration::from_secs(2), child.wait())
                        .await
                        .ok()
                        .and_then(Result::ok);
                    use std::os::unix::process::ExitStatusExt;
                    ProcessResult {
                        finish: if termination_confirmed {
                            finish
                        } else {
                            Finish::Unconfirmed
                        },
                        exit_code: status.as_ref().and_then(ExitStatus::code),
                        signal: status.as_ref().and_then(ExitStatusExt::signal),
                        success: false,
                        termination_confirmed,
                        scope_unit: unit.clone(),
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
