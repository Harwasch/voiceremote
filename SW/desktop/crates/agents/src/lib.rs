//! REQ-34/41/44: exact-session CLI dispatch only from a paired phone Noise session.
mod process;
pub mod receiver;
mod registry;
pub mod transport;
use anyhow::{Result, ensure};
pub use process::{CliAdapter, CloudAdapter, Finish, ProcessResult, UnconfiguredCloud};
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
    fn validate_caller(&self, session: &Session, command: &AuthorizedCommand) -> Result<()> {
        session.check_active()?;
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
        let required = if matches!(command.immutable_task_payload, ToolCall::CancelTaskTool(_)) {
            Capability::CancelTask
        } else {
            Capability::DelegateTask
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
        self.keys.put(key, &serde_json::to_vec(result)?)
    }
    fn stored(&self, key: &str) -> Result<Option<TaskResult>> {
        self.keys
            .get(key)?
            .map(|b| serde_json::from_slice(&b).map_err(Into::into))
            .transpose()
    }
    /// Only called synchronously for a message just decrypted by Session::receive.
    pub(crate) fn accept(&self, session: &Session, command: AuthorizedCommand) -> Admission {
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
        if self.validate_fresh(&command).is_err() {
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
            let active = self.active.lock().unwrap();
            if active.len() >= MAX_EXECUTIONS
                || active.values().any(|a| {
                    a.project == task.project_id && a.session == identity.provider_session_id
                })
            {
                return finish_now(Self::result(&command, Failed, Unavailable, None));
            }
            Some(identity)
        } else {
            None
        };
        match &command.immutable_task_payload {
            ToolCall::CancelTaskTool(task) => {
                let active = self.active.lock().unwrap();
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
            ToolCall::DelegateTaskTool(task) => {
                let (cancel, receive) = watch::channel(false);
                let identity = identity.unwrap();
                self.active.lock().unwrap().insert(
                    command.command_id.clone(),
                    Active {
                        peer: session.peer().id.clone(),
                        actor: command.authenticated_actor.clone(),
                        project: task.project_id.clone(),
                        session: identity.provider_session_id.clone(),
                        cancel,
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
        let ToolCall::DelegateTaskTool(task) = &work.command.immutable_task_payload else {
            unreachable!()
        };
        let execution = self.adapter.run(
            &work.identity,
            &task.instruction,
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
            Finish::Unconfirmed => (ExecutionState::Running, TaskStatusOutcome::Unavailable),
            Finish::Cancelled => (ExecutionState::Cancelled, TaskStatusOutcome::Error),
            Finish::NotConfigured | Finish::UnsupportedPlatform | Finish::SpawnFailed => {
                (ExecutionState::Failed, TaskStatusOutcome::Unavailable)
            }
            _ if process.success => (ExecutionState::Succeeded, TaskStatusOutcome::Ok),
            _ => (ExecutionState::Failed, TaskStatusOutcome::Error),
        };
        let confirmed = process.finish != Finish::Unconfirmed;
        let mut result = Self::result(&work.command, state, outcome, Some(process));
        if self.put_result(&work.key, &result).is_err() {
            result.status.execution_state = ExecutionState::Running;
            result.status.outcome = Some(TaskStatusOutcome::Unavailable);
        }
        if confirmed {
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
