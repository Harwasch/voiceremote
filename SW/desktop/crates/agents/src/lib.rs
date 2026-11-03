//! REQ-34/41/44: exact-session CLI dispatch only from a paired phone Noise session.
mod cloud;
mod process;
pub mod receiver;
mod registry;
pub mod transport;
#[cfg(windows)]
mod windows_job;
#[cfg(windows)]
mod windows_security;
use anyhow::{Result, ensure};
pub use cloud::{CloudConfig, CloudProvider, CloudReceipt, CloudState};
pub use process::{CliAdapter, Finish, ProcessResult};
pub use registry::{Allowlist, CapabilityProfile, Project, Provider, SessionIdentity};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::watch;
use voiceremote_core::{
    protocol::*,
    session::Session,
    storage::{KeyStore, Peer, Registry},
};
/// One LAN slot remains available for authenticated controls at the four-connection cap.
pub const MAX_EXECUTIONS: usize = 3;
static ADMISSION: Mutex<()> = Mutex::new(());
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
struct Active {
    peer: String,
    actor: String,
    project: String,
    session: String,
    cancel: watch::Sender<bool>,
    cloud: Option<CloudReceipt>,
}
#[derive(Clone)]
pub struct AgentNode {
    config: Arc<Allowlist>,
    adapter: CliAdapter,
    keys: Arc<dyn KeyStore>,
    active: Arc<Mutex<HashMap<String, Active>>>,
    completed: Arc<Mutex<VecDeque<TaskResult>>>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskResult {
    pub status: TaskStatus,
    pub process: Option<ProcessResult>,
}
pub(crate) struct Work {
    command: AuthorizedCommand,
    identity: SessionIdentity,
    key: String,
    receive: watch::Receiver<bool>,
    registry: Registry,
    peer: Peer,
}
pub(crate) struct Admission {
    pub result: TaskResult,
    pub work: Option<Work>,
}
impl AgentNode {
    pub fn new(
        mut config: Allowlist,
        adapter: CliAdapter,
        keys: Arc<dyn KeyStore>,
    ) -> Result<Self> {
        config.validate()?;
        Ok(Self {
            config: Arc::new(config),
            adapter,
            keys,
            active: Arc::new(Mutex::new(HashMap::new())),
            completed: Arc::new(Mutex::new(VecDeque::new())),
        })
    }
    pub fn recent_results(&self) -> Vec<TaskResult> {
        self.completed.lock().unwrap().iter().cloned().collect()
    }
    fn record_result(&self, result: TaskResult) {
        let mut completed = self.completed.lock().unwrap();
        if completed.len() == 128 {
            completed.pop_front();
        }
        completed.push_back(result);
    }
    /// Inventory is owner metadata, disclosed only to the enrolled controlling phone.
    pub(crate) fn inventory(
        &self,
        session: &Session,
        request: &AgentInventoryRequest,
    ) -> Result<AgentInventory> {
        self.check_phone(session, &request.account_id, Capability::DelegateTask)?;
        let sessions = self
            .config
            .sessions()?
            .into_iter()
            .map(|s| self.wire_session(&s, session))
            .collect::<Vec<_>>();
        let result = AgentInventory {
            kind: AgentInventoryKind::AgentInventory,
            account_id: self.config.account.clone(),
            device_id: self.config.host.clone(),
            request_id: request.request_id.clone(),
            authenticated_actor: self.config.actor.clone(),
            sessions,
        };
        encode(&result).map_err(anyhow::Error::msg)?;
        Ok(result)
    }
    fn check_phone(&self, session: &Session, account: &str, capability: Capability) -> Result<()> {
        session.check_active()?;
        let p = &session.peer().info;
        let local = session
            .registry()
            .local_info()?
            .ok_or_else(|| anyhow::anyhow!("missing identity"))?;
        ensure!(
            account == self.config.account
                && p.account_id == account
                && p.device_id == self.config.phone_device
                && p.platform == DeviceInfoPlatform::Ios
                && matches!(p.role, DeviceInfoRole::Capture | DeviceInfoRole::Both)
                && p.capabilities.contains(&capability)
                && local.account_id == account
                && local.device_id == self.config.host
                && local.capabilities.contains(&capability),
            "agent enrollment required"
        );
        Ok(())
    }
    fn wire_session(&self, s: &SessionIdentity, session: &Session) -> AgentSession {
        AgentSession {
            account_id: s.account.clone(),
            device_id: s.host.clone(),
            project_id: s.project.clone(),
            workspace: s.workspace.to_string_lossy().into_owned(),
            provider: match s.provider {
                Provider::Claude => AgentSessionProvider::Claude,
                Provider::Codex => AgentSessionProvider::Codex,
                Provider::Cloud => AgentSessionProvider::Cloud,
            },
            provider_session_id: s.provider_session_id.clone(),
            capability_profile: match s.capability_profile {
                CapabilityProfile::ReadOnly => AgentSessionCapabilityProfile::ReadOnly,
                CapabilityProfile::WorkspaceWrite => AgentSessionCapabilityProfile::WorkspaceWrite,
            },
            capabilities: [
                Capability::DelegateTask,
                Capability::CancelTask,
                Capability::OpenResource,
            ]
            .into_iter()
            .filter(|capability| {
                session.peer().info.capabilities.contains(capability)
                    && session
                        .registry()
                        .local_info()
                        .ok()
                        .flatten()
                        .is_some_and(|local| local.capabilities.contains(capability))
            })
            .collect(),
        }
    }
    pub(crate) fn query(&self, session: &Session, request: &AgentTaskQuery) -> Result<TaskStatus> {
        self.check_phone(session, &request.account_id, Capability::DelegateTask)?;
        let alias = format!(
            "agent-alias-{}",
            hex::encode(Sha256::digest(serde_json::to_vec(&(
                &session.peer().id,
                &request.command_id
            ))?))
        );
        let bytes = self
            .keys
            .get(&alias)?
            .ok_or_else(|| anyhow::anyhow!("unknown task"))?;
        let result = self
            .stored(std::str::from_utf8(&bytes)?)?
            .ok_or_else(|| anyhow::anyhow!("unknown receipt"))?;
        ensure!(
            result.status.account_id == request.account_id
                && result.status.command_id == request.command_id,
            "receipt identity"
        );
        Ok(result.status)
    }
    pub(crate) fn accept_dispatch(&self, session: &Session, dispatch: AgentDispatch) -> Admission {
        if dispatch.account_id != dispatch.command.account_id {
            return Admission {
                result: Self::result(
                    &dispatch.command,
                    ExecutionState::Failed,
                    TaskStatusOutcome::Denied,
                    None,
                ),
                work: None,
            };
        }
        if self.validate_caller(session, &dispatch.command).is_ok() {
            if let Ok(status) = self.query(
                session,
                &AgentTaskQuery {
                    kind: AgentTaskQueryKind::AgentTaskQuery,
                    account_id: dispatch.command.account_id.clone(),
                    command_id: dispatch.command.command_id.clone(),
                },
            ) {
                return Admission {
                    result: TaskResult {
                        status,
                        process: None,
                    },
                    work: None,
                };
            }
        }
        let valid = (|| -> Result<()> {
            self.validate_caller(session, &dispatch.command)?;
            let project = match &dispatch.command.immutable_task_payload {
                ToolCall::DelegateTaskTool(tool) => {
                    ensure!(
                        dispatch.command.provider_session_id.as_deref()
                            == Some(dispatch.session.provider_session_id.as_str()),
                        "session binding"
                    );
                    &tool.project_id
                }
                ToolCall::OpenResourceTool(_) => &dispatch.session.project_id,
                _ => anyhow::bail!("not agent action"),
            };
            let exact = self
                .config
                .resolve(project, &dispatch.session.provider_session_id)?;
            ensure!(
                dispatch.session == self.wire_session(&exact, session),
                "inventory changed; review again"
            );
            ensure!(now_ms() < dispatch.expires_at, "expired preview");
            use base64::Engine;
            let bytes =
                base64::engine::general_purpose::STANDARD.decode(&dispatch.immutable_preview)?;
            ensure!(
                hex::encode(Sha256::digest(&bytes)) == dispatch.command.payload_hash,
                "preview hash"
            );
            let preview: serde_json::Value = serde_json::from_slice(&bytes)?;
            ensure!(
                preview["tool"] == serde_json::to_value(&dispatch.command.immutable_task_payload)?
                    && preview["account"] == dispatch.command.account_id
                    && preview["actor"] == dispatch.command.authenticated_actor
                    && preview["device"] == dispatch.command.destination_id
                    && preview["project"] == *project
                    && preview["risk"] == serde_json::to_value(&dispatch.command.risk_class)?
                    && preview["expiresAt"] == dispatch.expires_at
                    && preview["request"] == dispatch.command.candidate_id
                    && preview["policy"] == dispatch.command.policy_version,
                "preview binding"
            );
            Ok(())
        })();
        if valid.is_err() {
            return Admission {
                result: Self::result(
                    &dispatch.command,
                    ExecutionState::Failed,
                    TaskStatusOutcome::Denied,
                    None,
                ),
                work: None,
            };
        }
        if matches!(
            dispatch.command.immutable_task_payload,
            ToolCall::OpenResourceTool(_)
        ) {
            self.accept_resource(session, dispatch)
        } else {
            self.accept(session, dispatch.command)
        }
    }
    fn accept_resource(&self, session: &Session, dispatch: AgentDispatch) -> Admission {
        let command = dispatch.command;
        let denied = || Admission {
            result: Self::result(
                &command,
                ExecutionState::Failed,
                TaskStatusOutcome::Denied,
                None,
            ),
            work: None,
        };
        let ToolCall::OpenResourceTool(tool) = &command.immutable_task_payload else {
            return denied();
        };
        // Preserve the original approved operation; only the provider handoff text is derived.
        if tool.account_id != command.account_id
            || tool.device_id != command.destination_id
            || command.risk_class != RiskClass::Sensitive
            || command.approval_event_id.is_none()
            || !matches!(
                command.approval_credential_class,
                ApprovalCredentialClass::Biometric | ApprovalCredentialClass::Passcode
            )
            || !tool.resource_uri.starts_with("https://")
        {
            return denied();
        }
        // Reuse all replay/admission logic with an explicit identity override; never
        // turn an arbitrary legacy open_resource command into a guessed route.
        let identity = match self.config.resolve(
            &dispatch.session.project_id,
            &dispatch.session.provider_session_id,
        ) {
            Ok(identity) => identity,
            Err(_) => return denied(),
        };
        self.admit(session, command, Some(identity))
    }
    fn validate_caller(&self, session: &Session, command: &AuthorizedCommand) -> Result<()> {
        self.check_phone(
            session,
            &command.account_id,
            match command.immutable_task_payload {
                ToolCall::CancelTaskTool(_) => Capability::CancelTask,
                ToolCall::OpenResourceTool(_) => Capability::OpenResource,
                _ => Capability::DelegateTask,
            },
        )?;
        encode(command).map_err(|_| anyhow::anyhow!("invalid command"))?;
        let peer = session.peer();
        let local = session
            .registry()
            .local_info()?
            .ok_or_else(|| anyhow::anyhow!("missing local identity"))?;
        ensure!(
            local.device_id == self.config.host && local.account_id == self.config.account,
            "node identity mismatch"
        );
        ensure!(
            peer.info.platform == DeviceInfoPlatform::Ios
                && peer.info.device_id == self.config.phone_device
                && peer.info.account_id == self.config.account,
            "unauthorized phone"
        );
        let matching = session
            .registry()
            .devices()?
            .into_iter()
            .filter(|p| {
                p.info.account_id == self.config.account
                    && p.info.device_id == self.config.phone_device
            })
            .collect::<Vec<_>>();
        ensure!(
            matching.len() == 1 && matching[0].id == peer.id,
            "ambiguous phone identity"
        );
        ensure!(
            command.account_id == self.config.account
                && command.destination_id == self.config.host
                && command.authenticated_actor == self.config.actor,
            "wrong command authority or destination"
        );
        ensure!(
            matches!(
                peer.info.role,
                DeviceInfoRole::Capture | DeviceInfoRole::Both
            ),
            "peer role cannot control agents"
        );
        let required = match command.immutable_task_payload {
            ToolCall::CancelTaskTool(_) => Capability::CancelTask,
            ToolCall::OpenResourceTool(_) => Capability::OpenResource,
            _ => Capability::DelegateTask,
        };
        ensure!(
            peer.info.capabilities.contains(&required),
            "paired peer lacks agent capability"
        );
        Ok(())
    }
    fn validate_fresh(&self, command: &AuthorizedCommand) -> Result<()> {
        ensure!(
            matches!(
                command.execution_state,
                ExecutionState::Queued | ExecutionState::Dispatched
            ) && command.outcome.is_none(),
            "not executable state"
        );
        let now = now_ms();
        ensure!(
            now > 0
                && command.created_at <= now
                && now
                    < command
                        .created_at
                        .saturating_add(self.config.max_command_age_ms)
                && command.created_at <= command.updated_at
                && command.updated_at <= now,
            "expired command"
        );
        match &command.immutable_task_payload {
            ToolCall::DelegateTaskTool(task) => {
                ensure!(
                    task.account_id == command.account_id && task.device_id == self.config.host,
                    "wrong task destination"
                );
                ensure!(
                    command.provider_session_id.is_some()
                        && command.provider_session_id == task.provider_session_id,
                    "missing or conflicting session"
                );
                // Opaque delegation is sensitive in the phone Policy tool table.
                // A model-supplied lower risk cannot weaken that floor here.
                ensure!(
                    command.risk_class == RiskClass::Sensitive
                        && command.approval_event_id.is_some()
                        && matches!(
                            command.approval_credential_class,
                            ApprovalCredentialClass::Biometric | ApprovalCredentialClass::Passcode
                        ),
                    "delegation requires phone authentication"
                );
                self.config.resolve(
                    &task.project_id,
                    command.provider_session_id.as_deref().unwrap(),
                )?;
            }
            ToolCall::CancelTaskTool(task) => {
                ensure!(
                    task.account_id == command.account_id,
                    "cross-account cancellation"
                );
            }
            _ => anyhow::bail!("unsupported agent command"),
        }
        Ok(())
    }
    fn result(
        command: &AuthorizedCommand,
        state: ExecutionState,
        outcome: TaskStatusOutcome,
        process: Option<ProcessResult>,
    ) -> TaskResult {
        TaskResult {
            status: TaskStatus {
                kind: TaskStatusKind::TaskStatus,
                account_id: command.account_id.clone(),
                command_id: command.command_id.clone(),
                execution_state: state,
                updated_at: now_ms(),
                outcome: Some(outcome),
                app_reply: process.as_ref().and_then(|p| p.app_reply.clone()),
            },
            process,
        }
    }
    fn storage_key(peer: &str, key: &str) -> String {
        format!(
            "agent-result-{}",
            hex::encode(Sha256::digest(serde_json::to_vec(&(peer, key)).unwrap()))
        )
    }
    fn unknown(command: &AuthorizedCommand) -> TaskResult {
        Self::result(
            command,
            ExecutionState::Running,
            TaskStatusOutcome::Unavailable,
            None,
        )
    }
    fn put_result(&self, key: &str, result: &TaskResult) -> Result<()> {
        let mut receipt = result.clone();
        receipt.status.app_reply = None;
        self.keys.put(key, &serde_json::to_vec(&receipt)?)
    }
    fn stored(&self, key: &str) -> Result<Option<TaskResult>> {
        self.keys
            .get(key)?
            .map(|b| -> Result<TaskResult> {
                let mut result: TaskResult = serde_json::from_slice(&b)?;
                // Pre-dispatched-contract receipts mistook clean CLI turns for
                // verified action success. Never revive that authority on replay.
                if result.status.execution_state == ExecutionState::Succeeded
                    && result
                        .process
                        .as_ref()
                        .is_some_and(|p| p.cloud.is_none() && p.finish == Finish::Completed)
                {
                    result.status.execution_state = ExecutionState::Dispatched;
                    result.status.outcome = Some(TaskStatusOutcome::Dispatched);
                }
                Ok(result)
            })
            .transpose()
    }
    /// Only called synchronously for a message just decrypted by Session::receive.
    pub(crate) fn accept(&self, session: &Session, command: AuthorizedCommand) -> Admission {
        self.admit(session, command, None)
    }
    fn admit(
        &self,
        session: &Session,
        command: AuthorizedCommand,
        resource_identity: Option<SessionIdentity>,
    ) -> Admission {
        use ExecutionState::{Failed, Running, Succeeded};
        use TaskStatusOutcome::{Denied, Error, Ok as Success, Unavailable};
        let done = |result| Admission { result, work: None };
        if self.validate_caller(session, &command).is_err() {
            return done(Self::result(&command, Failed, Denied, None));
        }
        let _gate = ADMISSION.lock().unwrap();
        let key = Self::storage_key(&session.peer().id, &command.idempotency_key);
        let alias = format!(
            "agent-alias-{}",
            hex::encode(Sha256::digest(
                serde_json::to_vec(&(&session.peer().id, &command.command_id)).unwrap()
            ))
        );
        // Lookup precedes new-command expiry checks: retry cannot overwrite a
        // running or completed command, including after node/process restart.
        let lookup = || -> Result<Option<TaskResult>> {
            if let Some(result) = self.stored(&key)? {
                return Ok(Some(result));
            }
            if let Some(bytes) = self.keys.get(&alias)? {
                let canonical = std::str::from_utf8(&bytes)?;
                return Ok(Some(
                    self.stored(canonical)?
                        .unwrap_or_else(|| Self::unknown(&command)),
                ));
            }
            Ok(None)
        };
        match lookup() {
            Ok(Some(result)) => return done(result),
            Err(_) => return done(Self::unknown(&command)),
            _ => {}
        }
        let claim = || -> Result<bool> {
            if !session.registry().claim_command(
                session.peer(),
                &format!("agent-key:{}", command.idempotency_key),
            )? {
                return Ok(false);
            }
            session
                .registry()
                .claim_command(session.peer(), &format!("agent-id:{}", command.command_id))
        };
        match claim() {
            Ok(true) => {}
            _ => return done(Self::unknown(&command)),
        }
        let initial = TaskResult {
            status: TaskStatus {
                kind: TaskStatusKind::TaskStatus,
                account_id: command.account_id.clone(),
                command_id: command.command_id.clone(),
                execution_state: Running,
                updated_at: now_ms(),
                outcome: None,
                app_reply: None,
            },
            process: None,
        };
        if self
            .put_result(&key, &initial)
            .and_then(|()| self.keys.put(&alias, key.as_bytes()))
            .is_err()
        {
            return done(Self::unknown(&command));
        }
        let finish_now = |result: TaskResult| {
            if self.put_result(&key, &result).is_err() {
                return done(Self::unknown(&command));
            }
            self.record_result(result.clone());
            done(result)
        };
        if !matches!(
            command.immutable_task_payload,
            ToolCall::DelegateTaskTool(_) | ToolCall::CancelTaskTool(_)
        ) && resource_identity.is_none()
        {
            return finish_now(Self::result(
                &command,
                Failed,
                Unavailable,
                Some(ProcessResult::no_process(Finish::UnsupportedAction)),
            ));
        }
        if if resource_identity.is_some() {
            let now = now_ms();
            !(matches!(
                command.execution_state,
                ExecutionState::Queued | ExecutionState::Dispatched
            ) && command.outcome.is_none()
                && command.created_at <= now
                && command.updated_at >= command.created_at
                && command.updated_at <= now
                && now
                    < command
                        .created_at
                        .saturating_add(self.config.max_command_age_ms))
        } else {
            self.validate_fresh(&command).is_err()
        } {
            return finish_now(Self::result(&command, Failed, Denied, None));
        }
        let identity = if let ToolCall::DelegateTaskTool(task) = &command.immutable_task_payload {
            let identity = match self.config.resolve(
                &task.project_id,
                command.provider_session_id.as_deref().unwrap(),
            ) {
                Ok(i) => i,
                Err(_) => return finish_now(Self::result(&command, Failed, Denied, None)),
            };
            Some(identity)
        } else {
            resource_identity
        };
        if let Some(identity) = &identity {
            let active = self.active.lock().unwrap();
            if active.len() >= MAX_EXECUTIONS
                || active.values().any(|a| {
                    a.project == identity.project && a.session == identity.provider_session_id
                })
            {
                return finish_now(Self::result(&command, Failed, Unavailable, None));
            }
        }
        match &command.immutable_task_payload {
            ToolCall::CancelTaskTool(task) => {
                let active = self.active.lock().unwrap();
                let cloud = active
                    .get(&task.command_id)
                    .filter(|target| {
                        target.peer == session.peer().id
                            && target.actor == command.authenticated_actor
                    })
                    .and_then(|target| {
                        let cloud = target.cloud.clone()?;
                        // Stop a launcher which may still be submitting. This is
                        // not evidence that an already created remote task stopped.
                        let _ = target.cancel.send(true);
                        Some(cloud)
                    });
                let target_alias = format!(
                    "agent-alias-{}",
                    hex::encode(Sha256::digest(
                        serde_json::to_vec(&(&session.peer().id, &task.command_id)).unwrap()
                    ))
                );
                let cloud = cloud.or_else(|| {
                    let bytes = self.keys.get(&target_alias).ok()??;
                    let target_key = std::str::from_utf8(&bytes).ok()?;
                    self.stored(target_key).ok()??.process?.cloud
                });
                if let Some(cloud) = cloud {
                    let mut process = ProcessResult::no_process(Finish::CancelUnsupported);
                    if cloud.state == CloudState::Unknown {
                        process.termination_confirmed = false;
                    }
                    process.cloud = Some(cloud);
                    return finish_now(Self::result(&command, Failed, Unavailable, Some(process)));
                }
                let acknowledged = active.get(&task.command_id).is_some_and(|target| {
                    target.peer == session.peer().id
                        && target.actor == command.authenticated_actor
                        && target.cancel.send(true).is_ok()
                });
                let result = Self::result(
                    &command,
                    if acknowledged { Succeeded } else { Failed },
                    if acknowledged { Success } else { Unavailable },
                    None,
                );
                if self.put_result(&key, &result).is_err() {
                    return done(Self::unknown(&command));
                }
                self.record_result(result.clone());
                done(result)
            }
            ToolCall::DelegateTaskTool(_) | ToolCall::OpenResourceTool(_) => {
                let (cancel, receive) = watch::channel(false);
                let identity = identity.unwrap();
                let mut initial = initial;
                if identity.provider == Provider::Cloud {
                    initial.process = Some(crate::cloud::result(&identity, Finish::Pending));
                    if self.put_result(&key, &initial).is_err() {
                        return done(Self::unknown(&command));
                    }
                }
                self.active.lock().unwrap().insert(
                    command.command_id.clone(),
                    Active {
                        peer: session.peer().id.clone(),
                        actor: command.authenticated_actor.clone(),
                        project: identity.project.clone(),
                        session: identity.provider_session_id.clone(),
                        cancel,
                        cloud: if identity.provider == Provider::Cloud {
                            crate::cloud::result(&identity, Finish::Pending).cloud
                        } else {
                            None
                        },
                    },
                );
                Admission {
                    result: initial,
                    work: Some(Work {
                        command,
                        identity,
                        key,
                        receive,
                        registry: session.registry().clone(),
                        peer: session.peer().clone(),
                    }),
                }
            }
            _ => done(Self::result(&command, Failed, Error, None)),
        }
    }
    pub(crate) async fn run(&self, work: Work) -> TaskResult {
        let instruction = match &work.command.immutable_task_payload {
            ToolCall::DelegateTaskTool(task) => task.instruction.clone(),
            ToolCall::OpenResourceTool(task) => format!(
                "Open this exact resource using your installed application's available tools: {}",
                task.resource_uri
            ),
            _ => unreachable!(),
        };
        let execution = self.adapter.run(
            &work.identity,
            &instruction,
            Duration::from_millis(self.config.timeout_ms),
            self.config.max_output_bytes,
            work.receive,
        );
        tokio::pin!(execution);
        let mut poll = tokio::time::interval(Duration::from_millis(100));
        let process = loop {
            tokio::select! {
                result=&mut execution=>break result,
                _=poll.tick()=>if work.registry.require(&work.peer).is_err(){self.cancel_id(&work.command.command_id);},
            }
        };
        let (state, outcome) = match process.finish {
            Finish::Unconfirmed | Finish::CloudSubmitted => {
                (ExecutionState::Running, TaskStatusOutcome::Unavailable)
            }
            Finish::Cancelled => (ExecutionState::Cancelled, TaskStatusOutcome::Error),
            Finish::NotConfigured | Finish::UnsupportedPlatform | Finish::SpawnFailed => {
                (ExecutionState::Failed, TaskStatusOutcome::Unavailable)
            }
            // A clean provider turn proves delivery, not completion of the requested action.
            // Owner policy requires verified predecessor success; dispatched never releases it.
            _ if process.success => (ExecutionState::Dispatched, TaskStatusOutcome::Dispatched),
            _ => (ExecutionState::Failed, TaskStatusOutcome::Error),
        };
        let confirmed = process.finish != Finish::Unconfirmed;
        let mut result = Self::result(&work.command, state, outcome, Some(process));
        if self.put_result(&work.key, &result).is_err() {
            result.status.execution_state = ExecutionState::Running;
            result.status.outcome = Some(TaskStatusOutcome::Unavailable);
        }
        if confirmed || work.identity.provider == Provider::Cloud {
            self.active.lock().unwrap().remove(&work.command.command_id);
        }
        self.record_result(result.clone());
        result
    }
    pub(crate) fn cancel_id(&self, id: &str) {
        if let Some(task) = self.active.lock().unwrap().get(id) {
            let _ = task.cancel.send(true);
        }
    }
    fn cancel_peer(&self, peer: &str) {
        for task in self
            .active
            .lock()
            .unwrap()
            .values()
            .filter(|a| a.peer == peer)
        {
            let _ = task.cancel.send(true);
        }
    }
}
