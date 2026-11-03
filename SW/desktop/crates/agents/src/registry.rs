//! Owner-selected projects and exact provider identities; no global session crawl.
use anyhow::{Result, ensure};
use serde::Deserialize;
use std::{collections::HashSet, fs, path::PathBuf};

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Claude,
    Codex,
    Cloud,
}
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum CapabilityProfile {
    #[default]
    ReadOnly,
    WorkspaceWrite,
}
impl CapabilityProfile {
    #[cfg(unix)]
    pub(crate) fn sandbox(self) -> &'static str {
        match self {
            Self::ReadOnly => "read-only",
            Self::WorkspaceWrite => "workspace-write",
        }
    }
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub project: String,
    pub workspace: PathBuf,
    pub provider: Provider,
    pub account: String,
    pub host: String,
    #[serde(default)]
    pub capability_profile: CapabilityProfile,
    #[serde(default)]
    pub sessions: Vec<String>,
    /// Optional owner-controlled metadata export outside all writable workspaces.
    #[serde(default)]
    pub discovery_file: Option<PathBuf>,
    /// Explicit owner opt-in, scoped to this project only.
    #[serde(default)]
    pub cloud: Option<crate::CloudConfig>,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Allowlist {
    pub account: String,
    pub host: String,
    pub phone_device: String,
    pub actor: String,
    #[serde(default = "command_age")]
    pub max_command_age_ms: u64,
    #[serde(default = "timeout")]
    pub timeout_ms: u64,
    #[serde(default = "output_limit")]
    pub max_output_bytes: usize,
    pub projects: Vec<Project>,
}
fn command_age() -> u64 {
    30_000
}
fn timeout() -> u64 {
    120_000
}
fn output_limit() -> usize {
    1024 * 1024
}
#[derive(Clone)]
pub struct SessionIdentity {
    pub provider: Provider,
    pub account: String,
    pub host: String,
    pub project: String,
    pub workspace: PathBuf,
    pub provider_session_id: String,
    pub capability_profile: CapabilityProfile,
    pub cloud: Option<crate::CloudConfig>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Discovered {
    sessions: Vec<DiscoveryEntry>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DiscoveryEntry {
    provider_session_id: String,
    workspace: PathBuf,
}
pub(crate) fn identifier(s: &str) -> bool {
    s.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
        && s.len() <= 128
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
impl Allowlist {
    pub fn load(path: &std::path::Path) -> Result<Self> {
        let metadata = fs::symlink_metadata(path)?;
        ensure!(
            metadata.is_file()
                && !metadata.file_type().is_symlink()
                && metadata.len() <= 256 * 1024,
            "unsafe allowlist"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};
            ensure!(
                metadata.uid() == unsafe { libc::geteuid() }
                    && metadata.permissions().mode() & 0o022 == 0,
                "allowlist must be owner-controlled"
            );
        }
        let mut config: Self = toml::from_str(&fs::read_to_string(path)?)?;
        config.validate()?;
        config.outside_workspaces(&path.canonicalize()?)?;
        Ok(config)
    }
    pub(crate) fn validate(&mut self) -> Result<()> {
        ensure!(
            identifier(&self.account)
                && identifier(&self.host)
                && identifier(&self.phone_device)
                && identifier(&self.actor),
            "invalid node identity"
        );
        ensure!(
            (1..=30_000).contains(&self.max_command_age_ms),
            "command lifetime exceeds approval bound"
        );
        ensure!(
            (1..=3_600_000).contains(&self.timeout_ms)
                && (64..=8 * 1024 * 1024).contains(&self.max_output_bytes),
            "invalid resource limits"
        );
        ensure!(self.projects.len() <= 256, "project limit");
        let mut names = HashSet::new();
        for project in &mut self.projects {
            ensure!(
                identifier(&project.project) && names.insert(project.project.clone()),
                "ambiguous project"
            );
            ensure!(
                project.account == self.account && project.host == self.host,
                "foreign project identity"
            );
            ensure!(
                project.workspace.is_absolute(),
                "workspace must be absolute"
            );
            project.workspace = project.workspace.canonicalize()?;
            ensure!(project.workspace.is_dir(), "workspace missing");
            ensure!(
                project.sessions.len() <= 256 && project.sessions.iter().all(|s| identifier(s)),
                "invalid session id"
            );
            let mut ids = HashSet::new();
            ensure!(
                project.sessions.iter().all(|s| ids.insert(s)),
                "duplicate session"
            );
            if let Some(cloud) = &project.cloud {
                ensure!(
                    project.provider == Provider::Cloud,
                    "cloud configuration on local provider"
                );
                cloud.validate()?;
            }
            if project.provider == Provider::Cloud {
                ensure!(
                    project.discovery_file.is_none(),
                    "cloud targets cannot discover local sessions"
                );
            }
            if let Some(file) = &project.discovery_file {
                let file = file.canonicalize()?;
                project.discovery_file = Some(file);
            }
        }
        for project in &self.projects {
            if let Some(file) = &project.discovery_file {
                self.outside_workspaces(file)?;
                Self::check_metadata(file)?;
            }
        }
        Ok(())
    }
    fn outside_workspaces(&self, file: &std::path::Path) -> Result<()> {
        ensure!(
            self.projects
                .iter()
                .all(|p| !file.starts_with(&p.workspace)),
            "owner configuration must be outside agent workspaces"
        );
        Ok(())
    }
    fn check_metadata(file: &std::path::Path) -> Result<()> {
        let meta = fs::symlink_metadata(file)?;
        ensure!(
            meta.is_file() && !meta.file_type().is_symlink() && meta.len() <= 64 * 1024,
            "unsafe discovery metadata"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};
            ensure!(
                meta.uid() == unsafe { libc::geteuid() } && meta.permissions().mode() & 0o022 == 0,
                "discovery metadata must be owner-controlled"
            );
        }
        Ok(())
    }
    pub fn sessions(&self) -> Result<Vec<SessionIdentity>> {
        let mut result = vec![];
        for project in &self.projects {
            // Recheck canonical paths at dispatch so swapped workspace symlinks deny.
            ensure!(
                project.workspace.canonicalize()? == project.workspace,
                "workspace changed"
            );
            let mut ids: HashSet<String> = project.sessions.iter().cloned().collect();
            if let Some(file) = &project.discovery_file {
                self.outside_workspaces(&file.canonicalize()?)?;
                Self::check_metadata(file)?;
                let discovered: Discovered = toml::from_str(&fs::read_to_string(file)?)?;
                ensure!(discovered.sessions.len() <= 256, "discovery session limit");
                for entry in discovered.sessions {
                    ensure!(
                        identifier(&entry.provider_session_id),
                        "invalid discovered session"
                    );
                    ensure!(
                        entry.workspace.is_absolute()
                            && entry.workspace.canonicalize()? == project.workspace,
                        "discovered session outside project"
                    );
                    ids.insert(entry.provider_session_id);
                }
            }
            for id in ids {
                result.push(SessionIdentity {
                    provider: project.provider,
                    account: project.account.clone(),
                    host: project.host.clone(),
                    project: project.project.clone(),
                    workspace: project.workspace.clone(),
                    provider_session_id: id,
                    capability_profile: project.capability_profile,
                    cloud: project.cloud.clone(),
                });
            }
        }
        Ok(result)
    }
    pub(crate) fn resolve(&self, project: &str, session: &str) -> Result<SessionIdentity> {
        self.sessions()?
            .into_iter()
            .find(|s| s.project == project && s.provider_session_id == session)
            .ok_or_else(|| anyhow::anyhow!("unknown project or session"))
    }
}
