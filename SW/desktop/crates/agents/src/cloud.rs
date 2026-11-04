//! Explicit project-scoped cloud handoffs; provider output is never retained.
use crate::{Finish, ProcessResult, SessionIdentity};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CloudProvider {
    Codex,
    Claude,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CloudConfig {
    #[serde(default)]
    pub enabled: bool,
    /// Explicit permission to use provider-environment permissions for a read-only route.
    /// Cloud CLIs do not enforce the local read-only capability profile.
    #[serde(default)]
    pub allow_read_only_override: bool,
    pub provider: CloudProvider,
    /// Owner-configured provider environment, including its repository access/policy.
    pub environment: String,
    /// Exact origin URL. Claude may upload this repository if its GitHub app is absent.
    pub repository: String,
    pub branch: String,
}
impl CloudConfig {
    pub(crate) fn validate(&self) -> Result<()> {
        ensure!(
            crate::registry::identifier(&self.environment),
            "invalid cloud environment"
        );
        let repo = self
            .repository
            .strip_prefix("https://github.com/")
            .or_else(|| self.repository.strip_prefix("git@github.com:"));
        ensure!(
            repo.is_some_and(|r| {
                let parts: Vec<_> = r.trim_end_matches(".git").split('/').collect();
                parts.len() == 2
                    && parts.iter().all(|p| {
                        !p.is_empty()
                            && *p != "."
                            && *p != ".."
                            && p.bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
                    })
            }),
            "cloud repository must be an explicit GitHub origin"
        );
        ensure!(
            !self.branch.is_empty()
                && self.branch.len() <= 256
                && self.branch.as_bytes()[0].is_ascii_alphanumeric()
                && self
                    .branch
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_/.".contains(&b))
                && !self.branch.contains("..")
                && !self.branch.ends_with('/'),
            "invalid cloud branch"
        );
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CloudState {
    NotConfigured,
    Unsupported,
    NotSubmitted,
    Submitted,
    Pending,
    Ready,
    Applied,
    Failed,
    Unknown,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CloudReceipt {
    /// Always cloud, including failure and cancellation receipts.
    pub label: String,
    pub provider: Option<CloudProvider>,
    pub task_id: Option<String>,
    pub state: CloudState,
    /// This adapter only creates independent tasks; local session IDs never leave the node.
    pub continues_local_session: bool,
    pub cancellation_supported: bool,
    /// Explicitly distinguishes provider permissions from a local read-only guarantee.
    #[serde(default)]
    pub permissions_label: String,
}
pub(crate) fn result(session: &SessionIdentity, finish: Finish) -> ProcessResult {
    let state = match finish {
        Finish::NotConfigured => CloudState::NotConfigured,
        Finish::UnsupportedPlatform | Finish::UnsupportedAction => CloudState::Unsupported,
        Finish::Pending | Finish::Unconfirmed => CloudState::Unknown,
        Finish::Cancelled | Finish::SpawnFailed => CloudState::NotSubmitted,
        _ => CloudState::Failed,
    };
    let pending = finish == Finish::Pending;
    let mut result = ProcessResult::no_process(finish);
    if pending {
        result.termination_confirmed = false;
    }
    result.cloud = Some(CloudReceipt {
        label: "cloud".into(),
        provider: session.cloud.as_ref().map(|c| c.provider),
        task_id: None,
        state,
        continues_local_session: false,
        cancellation_supported: false,
        permissions_label: if session.capability_profile == crate::CapabilityProfile::ReadOnly {
            if session
                .cloud
                .as_ref()
                .is_some_and(|c| c.allow_read_only_override)
            {
                "read-only override: provider environment permissions"
            } else {
                "read-only refused"
            }
        } else {
            "provider environment permissions"
        }
        .into(),
    });
    result
}
#[cfg(any(unix, windows))]
fn task_id(provider: CloudProvider, text: &str) -> Option<String> {
    let id = match provider {
        CloudProvider::Codex => text
            .trim()
            .strip_prefix("https://chatgpt.com/codex/tasks/")?,
        CloudProvider::Claude => {
            // Installed 2.1.312 headless creation output; JSON for cloud follow-ups
            // is a different contract and is deliberately not accepted here.
            let mut ids = text.lines().filter_map(|l| l.strip_prefix("Session ID: "));
            let id = ids.next()?;
            if ids.next().is_some() {
                return None;
            }
            id.trim()
        }
    };
    let prefix = match provider {
        CloudProvider::Codex => "task_",
        CloudProvider::Claude => "session_",
    };
    if !(id.starts_with(prefix) || (provider == CloudProvider::Claude && id.starts_with("cse_")))
        || !crate::registry::identifier(id)
        || id == prefix
        || id == "cse_"
    {
        return None;
    }
    Some(id.into())
}
#[cfg(any(unix, windows))]
pub(crate) fn submitted(session: &SessionIdentity, bytes: &[u8], exit_ok: bool) -> ProcessResult {
    let mut result = result(
        session,
        if exit_ok {
            Finish::InvalidOutput
        } else {
            Finish::CloudFailed
        },
    );
    let provider = session.cloud.as_ref().unwrap().provider;
    if let Ok(text) = std::str::from_utf8(bytes) {
        if let Some(id) = task_id(provider, text) {
            // A CLI which exits nonzero may already have created the task.
            // Keep the ID, but never report successful submission.
            if id != session.provider_session_id {
                let receipt = result.cloud.as_mut().unwrap();
                receipt.task_id = Some(id);
                receipt.state = if exit_ok {
                    CloudState::Submitted
                } else {
                    CloudState::Unknown
                };
                if exit_ok {
                    result.finish = Finish::CloudSubmitted;
                }
            }
        }
    }
    // Submission is not task completion. Missing output after exit zero is uncertain.
    if exit_ok && result.finish == Finish::InvalidOutput {
        result.finish = Finish::Unconfirmed;
        result.cloud.as_mut().unwrap().state = CloudState::Unknown;
    }
    result
}

#[cfg(any(unix, windows))]
impl crate::CliAdapter {
    pub(crate) async fn cloud_repository(&self, session: &SessionIdentity) -> bool {
        let Some(config) = &session.cloud else {
            return false;
        };
        if config.validate().is_err() {
            return false;
        }
        let origin = self
            .cloud_capture(
                "git",
                &["config", "--get", "remote.origin.url"],
                session,
                4096,
            )
            .await;
        let branch = self
            .cloud_capture("git", &["symbolic-ref", "--short", "HEAD"], session, 4096)
            .await;
        matches!((origin, branch), (Some((true, o)), Some((true, b)))
            if std::str::from_utf8(&o).is_ok_and(|v| v.trim() == config.repository)
                && std::str::from_utf8(&b).is_ok_and(|v| v.trim() == config.branch))
    }
    pub(crate) async fn cloud_snapshot(
        &self,
        session: &SessionIdentity,
        receipt: &mut CloudReceipt,
        limit: usize,
    ) {
        if receipt.provider != Some(CloudProvider::Codex) {
            return;
        }
        let Some(id) = &receipt.task_id else {
            return;
        };
        let Some((_, bytes)) = self
            .cloud_capture("codex", &["cloud", "status", id], session, limit)
            .await
        else {
            receipt.state = CloudState::Unknown;
            return;
        };
        // status exits 1 for PENDING/APPLIED as well as ERROR. Parse the exact
        // status marker, never infer completion/failure from the exit code alone.
        receipt.state = match std::str::from_utf8(&bytes)
            .ok()
            .and_then(|v| v.lines().next())
        {
            Some(v) if v.starts_with("[PENDING] ") => CloudState::Pending,
            Some(v) if v.starts_with("[READY] ") => CloudState::Ready,
            Some(v) if v.starts_with("[APPLIED] ") => CloudState::Applied,
            Some(v) if v.starts_with("[ERROR] ") => CloudState::Failed,
            _ => CloudState::Unknown,
        };
    }
}
