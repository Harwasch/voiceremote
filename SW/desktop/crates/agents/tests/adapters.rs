//! Synthetic payloads only; real providers are never invoked by default.
#![cfg(unix)]
use anyhow::Result;
use std::{fs, path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::watch;
use voiceremote_agents::*;
use voiceremote_core::{
    TextInjector,
    pairing::{self, Offer, SystemClock},
    protocol::*,
    session::Session,
    storage::{FileKeyStore, Identity, Registry},
    transport::{LanTransport, Transport},
};
struct NoInjection;
impl TextInjector for NoInjection {
    fn insert_text(&mut self, _: &str) -> Result<()> {
        anyhow::bail!("unexpected injection")
    }
}
fn info(id: &str, phone: bool) -> DeviceInfo {
    DeviceInfo {
        kind: DeviceInfoKind::DeviceInfo,
        account_id: "test-account".into(),
        device_id: id.into(),
        display_name: id.into(),
        platform: if phone {
            DeviceInfoPlatform::Ios
        } else {
            DeviceInfoPlatform::Linux
        },
        role: if phone {
            DeviceInfoRole::Capture
        } else {
            DeviceInfoRole::Agent
        },
        capabilities: vec![
            Capability::DelegateTask,
            Capability::CancelTask,
            Capability::OpenResource,
        ],
    }
}
struct Fixture {
    root: tempfile::TempDir,
    config: Allowlist,
    registry: Registry,
    phone_registry: Registry,
    pi: Identity,
    di: Arc<Identity>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        for project in &self.config.projects {
            if let Ok(text) = fs::read_to_string(project.workspace.join("child.pid")) {
                if let Ok(pid) = text.parse::<i32>() {
                    unsafe {
                        libc::kill(pid, libc::SIGKILL);
                    }
                }
            }
        }
    }
}
impl Fixture {
    fn new(provider: Provider) -> Result<Self> {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir()?;
        let bin = root.path().join("bin");
        fs::create_dir(&bin)?;
        for name in ["claude", "codex"] {
            let file = bin.join(name);
            fs::write(
                &file,
                r##"#!/usr/bin/python3
import sys, os, json, time, subprocess
text=sys.stdin.read()
args=sys.argv[1:]
with open('calls.jsonl','a') as f: f.write(json.dumps({'provider':os.path.basename(sys.argv[0]),'argv':args,'data':text,'env':sorted(os.environ)})+'\n')
if text == 'wait-tree':
    child=subprocess.Popen(['/usr/bin/python3','-c','import time; time.sleep(60)'], start_new_session=True)
    scope=os.environ.get('_VR_TEST_SCOPE_FILE')
    if scope:
        with open(scope) as f: state=json.load(f)
        state['pids'].append(child.pid)
        with open(scope,'w') as f: json.dump(state,f)
    with open('child.pid','w') as f: f.write(str(child.pid))
    while True: time.sleep(1)
if text == 'timeout': time.sleep(60)
if text == 'flood':
    while True: os.write(1,b'x'*4096)
if text == 'stderr-flood':
    while True: os.write(2,b'x'*4096)
if text == 'nonzero': sys.exit(7)
if text == 'malformed': print('not-json'); sys.exit(0)
if args[:2] == ['cloud', 'status']:
    try:
        with open('cloud-status') as f: status=f.read()
    except FileNotFoundError: status='PENDING'
    print('['+status+'] synthetic title')
    sys.exit(0 if status == 'READY' else 1)
if args[:2] == ['cloud', 'exec'] or '--cloud' in args:
    if text == 'wrong-session':
        print('https://chatgpt.com/codex/tasks/test-session'); sys.exit(0)
    if text == 'empty-success': sys.exit(0)
    if text == 'claude-json': print(json.dumps({'ok':True,'session_id':'session_fake'})); sys.exit(0)
    if '--cloud' in args:
        print('Created cloud session: '+('session_title' if text == 'id-shaped-title' else 'Synthetic task title'))
        if text != 'id-shaped-title': print('Session ID: session_fake')
        if text == 'duplicate-id': print('Session ID: session_other')
    else: print('https://chatgpt.com/codex/tasks/task_fake')
    sys.exit(0)
if '--resume' in args:
    session=args[args.index('--resume')+1]
    print(json.dumps({'type':'result','subtype':'success','is_error':False,'session_id':session if text != 'wrong-session' else 'other'}))
else:
    session=args[-2]
    print(json.dumps({'type':'thread.started','thread_id':session if text != 'wrong-session' else 'other'}))
    if text == 'error-only': print(json.dumps({'type':'error','message':'synthetic failure'})); sys.exit(0)
    if text == 'recovered-error': print(json.dumps({'type':'error','message':'synthetic reconnect warning'}))
    print(json.dumps({'type':'turn.failed' if text == 'provider-failed' else 'turn.completed'}))
"##,
            )?;
            fs::set_permissions(file, fs::Permissions::from_mode(0o700))?;
        }
        fs::create_dir(root.path().join("fake-scopes"))?;
        for (name, body) in [
            (
                "systemd-run",
                r##"#!/usr/bin/python3
import os,sys,json
root=os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
args=sys.argv[1:]
unit=args[args.index('--unit')+1]
with open(os.path.join(root,'scope-calls.jsonl'),'a') as f: f.write(json.dumps(args)+'\n')
scope=os.path.join(root,'fake-scopes',unit)
with open(scope,'w') as f: json.dump({'pids':[os.getpid()],'inactive':False},f)
os.environ['_VR_TEST_SCOPE_FILE']=scope
argv=args[args.index('--')+1:]
os.execvp(argv[0],argv)
"##,
            ),
            (
                "systemctl",
                r##"#!/usr/bin/python3
import os,sys,json,signal,time
root=os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
args=sys.argv[1:]
if '--property=Version' in args:
    if os.path.exists(os.path.join(root,'no-user-bus')): sys.exit(1)
    print('test-manager'); sys.exit(0)
if os.path.exists(os.path.join(root,'fail-control')): sys.exit(1)
if os.path.exists(os.path.join(root,'linger-tasks')):
    if '--property=ActiveState' in args: print('ActiveState=inactive\nTasksCurrent=1\nLoadState=loaded')
    sys.exit(0)
unit=args[-1]
path=os.path.join(root,'fake-scopes',unit)
try:
    with open(path) as f: state=json.load(f)
except FileNotFoundError: state={'pids':[],'inactive':True}
if 'kill' in args or 'stop' in args:
    for pid in state['pids']:
        try: os.kill(pid,signal.SIGKILL)
        except ProcessLookupError: pass
    state['inactive']=True
    with open(path,'w') as f: json.dump(state,f)
if '--property=ActiveState' in args:
    print('ActiveState='+('inactive' if state['inactive'] else 'active'))
    print('TasksCurrent='+('0' if state['inactive'] else str(len(state['pids']))))
    print('LoadState=loaded')
"##,
            ),
        ] {
            let path = bin.join(name);
            fs::write(&path, body)?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        }
        let config = Allowlist {
            account: "test-account".into(),
            host: "test-host".into(),
            phone_device: "test-phone".into(),
            actor: "test-owner".into(),
            max_command_age_ms: 30_000,
            timeout_ms: 1500,
            max_output_bytes: 4096,
            projects: vec![Project {
                project: "arm-design".into(),
                workspace: root.path().to_path_buf(),
                provider,
                account: "test-account".into(),
                host: "test-host".into(),
                capability_profile: CapabilityProfile::ReadOnly,
                sessions: vec!["test-session".into()],
                discovery_file: None,
                cloud: None,
            }],
        };
        Ok(Self {
            registry: Registry::new(Arc::new(FileKeyStore::new(
                root.path().join("desktop-state"),
            )?)),
            phone_registry: Registry::new(Arc::new(FileKeyStore::new(
                root.path().join("phone-state"),
            )?)),
            pi: Identity::generate()?,
            di: Arc::new(Identity::generate()?),
            root,
            config,
        })
    }
    fn node(&self) -> Result<AgentNode> {
        AgentNode::new(
            self.config.clone(),
            CliAdapter::with_path(self.root.path().join("bin").into_os_string()),
            Arc::new(FileKeyStore::new(self.root.path().join("desktop-state"))?),
        )
    }
    async fn pair(
        &self,
    ) -> Result<(
        Session,
        Box<dyn Transport>,
        Session,
        voiceremote_agents::transport::PacketTransport,
    )> {
        let listener =
            voiceremote_agents::transport::Listener::bind("127.0.0.1:0".parse()?).await?;
        let (p, d) = tokio::join!(
            LanTransport::connect(listener.address()?),
            listener.accept()
        );
        self.pair_on(Box::new(p?), d?).await
    }
    async fn pair_on(
        &self,
        mut p: Box<dyn Transport>,
        mut d: voiceremote_agents::transport::PacketTransport,
    ) -> Result<(
        Session,
        Box<dyn Transport>,
        Session,
        voiceremote_agents::transport::PacketTransport,
    )> {
        if let (Some(pp), Some(dp)) = (
            self.phone_registry.devices()?.into_iter().next(),
            self.registry.devices()?.into_iter().next(),
        ) {
            let (ps, ds) = tokio::join!(
                pairing::resume_initiate(
                    p.as_mut(),
                    &self.pi,
                    &self.phone_registry,
                    &pp,
                    "test-phone"
                ),
                pairing::resume_accept(&mut d, &self.di, &self.registry, &dp, "test-host")
            );
            return Ok((ps?, p, ds?, d));
        }
        let mut offer = Offer::issue(
            &self.di,
            "test-account".into(),
            "test-room".into(),
            &SystemClock,
        )?;
        let payload = offer.payload.clone();
        let (p1, d1) = tokio::join!(
            pairing::initiate(p.as_mut(), &self.pi, &payload, &SystemClock),
            pairing::accept(&mut d, &self.di, &mut offer, &SystemClock)
        );
        let (mut p1, mut d1) = (p1?, d1?);
        let phrase = p1.phrase();
        p1.confirm_local(p.as_mut(), &phrase, info("test-phone", true))
            .await?;
        d1.confirm_local(&mut d, &phrase, info("test-host", false))
            .await?;
        let (a, b) = tokio::join!(
            p1.receive_confirmation(p.as_mut()),
            d1.receive_confirmation(&mut d)
        );
        a?;
        b?;
        Ok((
            p1.finish(self.phone_registry.clone())?,
            p,
            d1.finish(self.registry.clone())?,
            d,
        ))
    }
    async fn call(&self, node: AgentNode, command: AuthorizedCommand) -> Result<TaskStatus> {
        let (mut p, mut pt, d, mut dt) = self.pair().await?;
        let (stop, rx) = watch::channel(false);
        let task =
            tokio::spawn(
                async move { receiver::serve(&node, d, &mut dt, &mut NoInjection, rx).await },
            );
        p.send(pt.as_mut(), &InnerMessage::AuthorizedCommand(command))
            .await?;
        let status = tokio::time::timeout(Duration::from_secs(6), async {
            loop {
                let message = p.receive(pt.as_mut()).await?;
                if let InnerMessage::TaskStatus(ref status) = message {
                    if matches!(
                        status.execution_state,
                        ExecutionState::Succeeded
                            | ExecutionState::Failed
                            | ExecutionState::Cancelled
                    ) || status.outcome == Some(TaskStatusOutcome::Unavailable)
                    {
                        break Ok::<_, anyhow::Error>(message);
                    }
                }
            }
        })
        .await??;
        stop.send(true)?;
        let _ = task.await?;
        let InnerMessage::TaskStatus(status) = status else {
            anyhow::bail!("expected status")
        };
        Ok(status)
    }
    fn calls(&self) -> Vec<serde_json::Value> {
        fs::read_to_string(self.root.path().join("calls.jsonl"))
            .unwrap_or_default()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect()
    }
}
fn command(key: &str, text: &str) -> AuthorizedCommand {
    AuthorizedCommand {
        kind: AuthorizedCommandKind::AuthorizedCommand,
        account_id: "test-account".into(),
        command_id: key.into(),
        candidate_id: "test-candidate".into(),
        immutable_task_payload: ToolCall::DelegateTaskTool(DelegateTaskTool {
            kind: DelegateTaskToolKind::DelegateTask,
            account_id: "test-account".into(),
            device_id: "test-host".into(),
            project_id: "arm-design".into(),
            provider_session_id: Some("test-session".into()),
            instruction: text.into(),
        }),
        payload_hash: "a".repeat(64),
        source_tier: AuthorizedCommandSourceTier::Explicit,
        activation_kind: ActivationKind::ApprovalTap,
        authenticated_actor: "test-owner".into(),
        approval_credential_class: ApprovalCredentialClass::Passcode,
        approval_event_id: Some("test-approval".into()),
        risk_class: RiskClass::Sensitive,
        policy_version: "test-policy".into(),
        granted_scope_id: "test-scope".into(),
        destination_id: "test-host".into(),
        provider_session_id: Some("test-session".into()),
        idempotency_key: key.into(),
        execution_state: ExecutionState::Queued,
        outcome: None,
        created_at: now_ms(),
        updated_at: now_ms(),
    }
}
#[tokio::test]
async fn named_sessions_route_to_right_fake_and_transcript_never_changes_argv() -> Result<()> {
    for provider in [Provider::Claude, Provider::Codex] {
        let mut f = Fixture::new(provider)?;
        f.config.projects[0]
            .sessions
            .insert(0, "wrong-first-session".into());
        let mut other = f.config.projects[0].clone();
        other.project = "other-project".into();
        other.workspace = f.root.path().join("other");
        fs::create_dir(&other.workspace)?;
        other.sessions = vec!["other-session".into()];
        f.config.projects.insert(0, other);
        let text = "--dangerously-skip-permissions -s danger-full-access; $(touch SHOULD_NOT_EXIST) `echo test`\n--resume another";
        let status = f.call(f.node()?, command("route", text)).await?;
        assert_eq!(status.execution_state, ExecutionState::Succeeded);
        let calls = f.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["data"], text);
        assert_eq!(
            calls[0]["provider"],
            if provider == Provider::Claude {
                "claude"
            } else {
                "codex"
            }
        );
        let expected = if provider == Provider::Claude {
            vec![
                "-p",
                "--resume",
                "test-session",
                "--output-format",
                "json",
                "--tools",
                "Read,Glob,Grep",
                "--restricted",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--settings",
                "{\"disableAllHooks\":true}",
            ]
        } else {
            vec![
                "-a",
                "never",
                "exec",
                "-s",
                "read-only",
                "resume",
                "--json",
                "test-session",
                "-",
            ]
        };
        assert_eq!(calls[0]["argv"], serde_json::json!(expected));
        assert!(!f.root.path().join("SHOULD_NOT_EXIST").exists());
        f.config
            .projects
            .iter_mut()
            .find(|p| p.project == "arm-design")
            .unwrap()
            .capability_profile = CapabilityProfile::WorkspaceWrite;
        assert_eq!(
            f.call(f.node()?, command("write-profile", "synthetic"))
                .await?
                .outcome,
            Some(TaskStatusOutcome::Ok)
        );
        let write_calls = f.calls();
        let expected_write = if provider == Provider::Claude {
            vec![
                "-p",
                "--resume",
                "test-session",
                "--output-format",
                "json",
                "--tools",
                "Read,Glob,Grep,Edit,Write",
                "--restricted",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--settings",
                r#"{"disableAllHooks":true}"#,
            ]
        } else {
            vec![
                "-a",
                "never",
                "exec",
                "-s",
                "workspace-write",
                "resume",
                "--json",
                "test-session",
                "-",
            ]
        };
        assert_eq!(write_calls[1]["argv"], serde_json::json!(expected_write));
        let scope_calls = fs::read_to_string(f.root.path().join("scope-calls.jsonl"))?
            .lines()
            .map(serde_json::from_str::<Vec<String>>)
            .collect::<std::result::Result<Vec<_>, _>>()?;
        assert_eq!(scope_calls.len(), 2);
        let units = scope_calls
            .iter()
            .map(|args| {
                assert!(args.iter().any(|a| a == "--user"));
                assert!(args.iter().any(|a| a == "--scope"));
                assert!(!args.iter().any(|a| a == text));
                args[args.iter().position(|a| a == "--unit").unwrap() + 1].clone()
            })
            .collect::<Vec<_>>();
        assert_ne!(units[0], units[1]);
        let env = calls[0]["env"].as_array().unwrap();
        assert!(env.iter().all(|key| {
            [
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
                "LC_CTYPE",
                "_VR_TEST_SCOPE_FILE",
                "XDG_RUNTIME_DIR",
                "DBUS_SESSION_BUS_ADDRESS",
            ]
            .contains(&key.as_str().unwrap())
        }));
    }
    Ok(())
}
#[tokio::test]
async fn unknown_project_or_session_missing_session_wrong_device_expired_or_unauthorized_denied()
-> Result<()> {
    let f = Fixture::new(Provider::Claude)?;
    let node = f.node()?;
    for mode in 0..9 {
        let mut c = command(&format!("reject-{mode}"), "synthetic");
        match mode {
            0 => {
                if let ToolCall::DelegateTaskTool(t) = &mut c.immutable_task_payload {
                    t.project_id = "unknown".into();
                }
            }
            1 => {
                c.provider_session_id = Some("unknown".into());
                if let ToolCall::DelegateTaskTool(t) = &mut c.immutable_task_payload {
                    t.provider_session_id = c.provider_session_id.clone();
                }
            }
            2 => {
                c.provider_session_id = None;
                if let ToolCall::DelegateTaskTool(t) = &mut c.immutable_task_payload {
                    t.provider_session_id = None;
                }
            }
            3 => c.destination_id = "wrong-host".into(),
            4 => {
                c.created_at = now_ms() - 30_001;
                c.updated_at = c.created_at;
            }
            5 => c.authenticated_actor = "wrong-owner".into(),
            6 => {
                c.risk_class = RiskClass::ReadDisplay;
                c.activation_kind = ActivationKind::Ptt;
                c.approval_credential_class = ApprovalCredentialClass::ScopedGrant;
                c.approval_event_id = None;
            }
            7 => c.created_at = now_ms() + 60_000,
            _ => {
                if let ToolCall::DelegateTaskTool(t) = &mut c.immutable_task_payload {
                    t.device_id = "wrong-host".into();
                }
            }
        }
        assert_eq!(
            f.call(node.clone(), c).await?.outcome,
            Some(TaskStatusOutcome::Denied)
        );
    }
    // The encrypted peer is real but not the configured phone.
    let mut config = f.config.clone();
    config.phone_device = "another-phone".into();
    let node = AgentNode::new(
        config,
        CliAdapter::default(),
        Arc::new(FileKeyStore::new(f.root.path().join("desktop-state"))?),
    )?;
    assert_eq!(
        f.call(node, command("wrong-phone", "synthetic"))
            .await?
            .outcome,
        Some(TaskStatusOutcome::Denied)
    );
    f.registry
        .enroll(vec![42; 32], "test-room".into(), info("test-phone", true))?;
    assert_eq!(
        f.call(f.node()?, command("ambiguous-phone", "synthetic"))
            .await?
            .outcome,
        Some(TaskStatusOutcome::Denied)
    );
    assert!(f.calls().is_empty());
    Ok(())
}
#[tokio::test]
async fn replay_runs_once_across_restart_even_with_changed_payload() -> Result<()> {
    let mut f = Fixture::new(Provider::Codex)?;
    assert_eq!(
        f.call(f.node()?, command("once", "synthetic"))
            .await?
            .outcome,
        Some(TaskStatusOutcome::Ok)
    );
    f.registry = Registry::new(Arc::new(FileKeyStore::new(
        f.root.path().join("desktop-state"),
    )?));
    assert_eq!(
        f.call(f.node()?, command("once", "different synthetic"))
            .await?
            .outcome,
        Some(TaskStatusOutcome::Ok)
    );
    assert_eq!(f.calls().len(), 1);
    Ok(())
}
#[tokio::test]
async fn nonzero_timeout_output_overflow_and_bad_structured_results_fail() -> Result<()> {
    for provider in [Provider::Claude, Provider::Codex] {
        let mut f = Fixture::new(provider)?;
        // Deterministically reproduce a loaded runner's launcher startup. These
        // fakes do not use a real user bus; both Python startups count against
        // the task deadline, before the requested nonzero exit can execute.
        let launcher = f.root.path().join("bin/systemd-run");
        let body = fs::read_to_string(&launcher)?;
        fs::write(
            &launcher,
            body.replace(
                "import os,sys,json",
                "import os,sys,json,time\ntime.sleep(.3)",
            ),
        )?;
        for (n, text) in [
            "nonzero",
            "timeout",
            "flood",
            "stderr-flood",
            "malformed",
            "wrong-session",
        ]
        .iter()
        .enumerate()
        {
            // Exit/format/overflow assertions must reach the fake provider even
            // on a loaded runner. Keep the deliberately hung case at 200 ms.
            f.config.timeout_ms = if *text == "timeout" { 200 } else { 5_000 };
            let node = f.node()?;
            let status = f
                .call(node.clone(), command(&format!("fail-{n}"), text))
                .await?;
            assert_eq!(status.execution_state, ExecutionState::Failed);
            assert_eq!(status.outcome, Some(TaskStatusOutcome::Error));
            let results = node.recent_results();
            let result = results.last().unwrap().process.as_ref().unwrap();
            if *text == "nonzero" {
                assert_eq!(
                    result.exit_code,
                    Some(7),
                    "finish={:?}, signal={:?}, calls={}",
                    result.finish,
                    result.signal,
                    f.calls().len()
                );
            }
            if *text == "timeout" {
                assert_eq!(result.finish, Finish::TimedOut);
                assert_eq!(result.signal, Some(9));
            }
        }
    }
    Ok(())
}
async fn wait_file(path: PathBuf) {
    tokio::time::timeout(Duration::from_secs(3), async {
        while !path.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}
fn process_alive(pid: i32) -> bool {
    // A reparented zombie is already dead; this container's PID 1 may not reap.
    let text = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
    !text.is_empty() && !text.split(") ").nth(1).unwrap_or("").starts_with('Z')
}
#[tokio::test]
async fn authorized_cancel_on_second_noise_connection_kills_tree() -> Result<()> {
    let mut f = Fixture::new(Provider::Claude)?;
    f.config.timeout_ms = 10_000;
    let node = f.node()?;
    let (mut p, mut pt, d, mut dt) = f.pair().await?;
    let (stop, rx) = watch::channel(false);
    let worker = node.clone();
    let server =
        tokio::spawn(
            async move { receiver::serve(&worker, d, &mut dt, &mut NoInjection, rx).await },
        );
    p.send(
        pt.as_mut(),
        &InnerMessage::AuthorizedCommand(command("long-task", "wait-tree")),
    )
    .await?;
    wait_file(f.root.path().join("child.pid")).await;
    let pid: i32 = fs::read_to_string(f.root.path().join("child.pid"))?.parse()?;
    assert!(process_alive(pid));
    let mut cancel = command("cancel-request", "synthetic");
    cancel.immutable_task_payload = ToolCall::CancelTaskTool(CancelTaskTool {
        kind: CancelTaskToolKind::CancelTask,
        account_id: "test-account".into(),
        command_id: "long-task".into(),
    });
    assert_eq!(
        f.call(node, cancel).await?.outcome,
        Some(TaskStatusOutcome::Ok)
    );
    let status = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let status = p.receive(pt.as_mut()).await?;
            if let InnerMessage::TaskStatus(status) = status {
                if status.execution_state != ExecutionState::Running {
                    break Ok::<_, anyhow::Error>(status);
                }
            }
        }
    })
    .await??;
    assert_eq!(status.execution_state, ExecutionState::Cancelled);
    tokio::time::timeout(Duration::from_secs(2), async {
        while process_alive(pid) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await?;
    stop.send(true)?;
    let _ = server.await?;
    Ok(())
}
#[tokio::test]
async fn cloud_is_explicitly_not_configured() -> Result<()> {
    let f = Fixture::new(Provider::Cloud)?;
    assert_eq!(
        f.call(f.node()?, command("cloud", "synthetic"))
            .await?
            .outcome,
        Some(TaskStatusOutcome::Unavailable)
    );
    assert!(f.calls().is_empty());
    Ok(())
}
#[test]
fn owner_allowlist_and_discovery_reject_paths_and_unsafe_profiles() -> Result<()> {
    let f = Fixture::new(Provider::Codex)?;
    let metadata_root = tempfile::tempdir()?;
    let file = metadata_root.path().join("discovered.toml");
    fs::write(
        &file,
        format!(
            "[[sessions]]\nprovider_session_id='discovered-id'\nworkspace={:?}\n",
            f.root.path().to_str().unwrap()
        ),
    )?;
    let mut config = f.config.clone();
    config.projects[0].discovery_file = Some(file.clone());
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&file, fs::Permissions::from_mode(0o666))?;
    assert!(
        AgentNode::new(
            config.clone(),
            CliAdapter::default(),
            Arc::new(FileKeyStore::new(f.root.path().join("desktop-state"))?)
        )
        .is_err()
    );
    fs::set_permissions(&file, fs::Permissions::from_mode(0o600))?;
    let node = AgentNode::new(
        config.clone(),
        CliAdapter::default(),
        Arc::new(FileKeyStore::new(f.root.path().join("desktop-state"))?),
    );
    assert!(node.is_ok());
    assert_eq!(config.sessions()?.len(), 2);
    fs::write(
        file,
        "[[sessions]]\nprovider_session_id='foreign'\nworkspace='/tmp'\n",
    )?;
    assert!(config.sessions().is_err());
    let mut unsafe_config = f.config.clone();
    let inside = f.root.path().join("discovery.toml");
    fs::write(&inside, "sessions=[]")?;
    unsafe_config.projects[0].discovery_file = Some(inside);
    assert!(
        AgentNode::new(
            unsafe_config,
            CliAdapter::default(),
            Arc::new(FileKeyStore::new(f.root.path().join("desktop-state"))?)
        )
        .is_err()
    );
    let raw = "account='test-account'\nhost='test-host'\nphone_device='test-phone'\nactor='test-owner'\n[[projects]]\nproject='x'\nworkspace='/tmp'\nprovider='codex'\naccount='test-account'\nhost='test-host'\ncapability_profile='danger-full-access'\n";
    assert!(toml::from_str::<Allowlist>(raw).is_err());
    Ok(())
}

#[tokio::test]
async fn receive_text_only_phone_cannot_delegate() -> Result<()> {
    let f = Fixture::new(Provider::Claude)?;
    let (_p, _pt, _d, _dt) = f.pair().await?;
    for role in [DeviceInfoRole::Capture, DeviceInfoRole::TextReceiver] {
        let mut restricted = info("test-phone", true);
        restricted.capabilities = if role == DeviceInfoRole::Capture {
            vec![Capability::ReceiveText]
        } else {
            vec![Capability::DelegateTask, Capability::CancelTask]
        };
        restricted.role = role;
        f.registry
            .enroll(f.pi.public.clone(), "test-room".into(), restricted)?;
        assert_eq!(
            f.call(f.node()?, command("restricted", "synthetic"))
                .await?
                .outcome,
            Some(TaskStatusOutcome::Denied)
        );
    }
    let mut restricted = info("test-phone", true);
    restricted.capabilities = vec![Capability::DelegateTask];
    f.registry
        .enroll(f.pi.public.clone(), "test-room".into(), restricted)?;
    let mut cancel = command("no-cancel-capability", "synthetic");
    cancel.immutable_task_payload = ToolCall::CancelTaskTool(CancelTaskTool {
        kind: CancelTaskToolKind::CancelTask,
        account_id: "test-account".into(),
        command_id: "unknown".into(),
    });
    assert_eq!(
        f.call(f.node()?, cancel).await?.outcome,
        Some(TaskStatusOutcome::Denied)
    );
    assert!(f.calls().is_empty());
    Ok(())
}
#[test]
fn dash_leading_session_ids_are_rejected_and_profile_defaults_safe() -> Result<()> {
    let f = Fixture::new(Provider::Claude)?;
    for id in ["-session", "--resume", "space session", "a/b", "a;cmd"] {
        let mut config = f.config.clone();
        config.projects[0].sessions = vec![id.into()];
        assert!(
            AgentNode::new(
                config,
                CliAdapter::default(),
                Arc::new(FileKeyStore::new(f.root.path().join("desktop-state"))?)
            )
            .is_err(),
            "accepted {id}"
        );
    }
    let text = format!(
        "project='safe'\nworkspace={:?}\nprovider='claude'\naccount='test-account'\nhost='test-host'\n",
        f.root.path().to_str().unwrap()
    );
    assert_eq!(
        toml::from_str::<Project>(&text)?.capability_profile,
        CapabilityProfile::ReadOnly
    );
    Ok(())
}
#[tokio::test]
async fn codex_recovered_error_before_completed_turn_is_success() -> Result<()> {
    let f = Fixture::new(Provider::Codex)?;
    assert_eq!(
        f.call(f.node()?, command("recovered", "recovered-error"))
            .await?
            .outcome,
        Some(TaskStatusOutcome::Ok)
    );
    Ok(())
}
#[tokio::test]
async fn cancel_on_same_noise_connection_is_read_while_task_runs() -> Result<()> {
    let mut f = Fixture::new(Provider::Claude)?;
    f.config.timeout_ms = 10_000;
    let node = f.node()?;
    let (mut p, mut pt, d, mut dt) = f.pair().await?;
    let (stop, rx) = watch::channel(false);
    let server =
        tokio::spawn(async move { receiver::serve(&node, d, &mut dt, &mut NoInjection, rx).await });
    p.send(
        pt.as_mut(),
        &InnerMessage::AuthorizedCommand(command("same-channel-task", "wait-tree")),
    )
    .await?;
    wait_file(f.root.path().join("child.pid")).await;
    let mut cancel = command("same-channel-cancel", "synthetic");
    cancel.immutable_task_payload = ToolCall::CancelTaskTool(CancelTaskTool {
        kind: CancelTaskToolKind::CancelTask,
        account_id: "test-account".into(),
        command_id: "same-channel-task".into(),
    });
    p.send(pt.as_mut(), &InnerMessage::AuthorizedCommand(cancel))
        .await?;
    tokio::time::timeout(Duration::from_millis(700), async {
        loop {
            if let InnerMessage::TaskStatus(status) = p.receive(pt.as_mut()).await? {
                if status.command_id == "same-channel-cancel" {
                    assert_eq!(status.outcome, Some(TaskStatusOutcome::Ok));
                    break Ok::<_, anyhow::Error>(());
                }
            }
        }
    })
    .await??;
    let status = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let InnerMessage::TaskStatus(status) = p.receive(pt.as_mut()).await? {
                if status.command_id == "same-channel-task"
                    && status.execution_state != ExecutionState::Running
                {
                    break Ok::<_, anyhow::Error>(status);
                }
            }
        }
    })
    .await??;
    assert_eq!(status.execution_state, ExecutionState::Cancelled);
    let pid: i32 = fs::read_to_string(f.root.path().join("child.pid"))?.parse()?;
    assert!(!process_alive(pid));
    stop.send(true)?;
    let _ = server.await?;
    Ok(())
}

#[tokio::test]
async fn timeout_kills_setsid_child_and_no_bus_or_failed_stop_never_claims_cancelled() -> Result<()>
{
    for mode in ["contained", "no-user-bus", "fail-control", "linger-tasks"] {
        let mut f = Fixture::new(Provider::Claude)?;
        // Allow Python/launcher startup under capped concurrent tests before
        // asserting timeout cleanup of the deliberately escaped child.
        f.config.timeout_ms = 1500;
        if mode != "contained" {
            fs::write(f.root.path().join(mode), "")?;
        }
        let node = f.node()?;
        let status = f
            .call(node.clone(), command("tree-timeout", "wait-tree"))
            .await?;
        let pid: i32 = fs::read_to_string(f.root.path().join("child.pid"))?.parse()?;
        let results = node.recent_results();
        let process = results.last().unwrap().process.as_ref().unwrap();
        if mode == "contained" {
            assert_eq!(status.execution_state, ExecutionState::Failed);
            assert_eq!(process.finish, Finish::TimedOut);
            assert!(process.termination_confirmed);
            assert!(!process_alive(pid));
        } else {
            assert_eq!(status.execution_state, ExecutionState::Running);
            assert_eq!(status.outcome, Some(TaskStatusOutcome::Unavailable));
            assert_eq!(process.finish, Finish::Unconfirmed);
            assert!(!process.termination_confirmed);
            assert!(
                process_alive(pid),
                "escaped child must expose fallback's uncertainty"
            );
            let retry = f
                .call(f.node()?, command("tree-timeout", "changed synthetic"))
                .await?;
            assert_eq!(retry.execution_state, ExecutionState::Running);
            assert_eq!(retry.outcome, Some(TaskStatusOutcome::Unavailable));
            assert_eq!(f.calls().len(), 1);
        }
    }
    Ok(())
}
#[tokio::test]
async fn revoke_read_during_execution_stops_escaped_child() -> Result<()> {
    let mut f = Fixture::new(Provider::Codex)?;
    f.config.timeout_ms = 10_000;
    let node = f.node()?;
    let worker = node.clone();
    let (mut p, mut pt, d, mut dt) = f.pair().await?;
    let (_stop, rx) = watch::channel(false);
    let server =
        tokio::spawn(
            async move { receiver::serve(&worker, d, &mut dt, &mut NoInjection, rx).await },
        );
    p.send(
        pt.as_mut(),
        &InnerMessage::AuthorizedCommand(command("revoked-task", "wait-tree")),
    )
    .await?;
    wait_file(f.root.path().join("child.pid")).await;
    let pid: i32 = fs::read_to_string(f.root.path().join("child.pid"))?.parse()?;
    p.send(
        pt.as_mut(),
        &InnerMessage::Revoke(Revoke {
            kind: RevokeKind::Revoke,
            account_id: "test-account".into(),
            device_id: "test-host".into(),
            command_id: "revoke".into(),
            idempotency_key: "revoke".into(),
            revoked_at: now_ms(),
        }),
    )
    .await?;
    tokio::time::timeout(Duration::from_secs(3), server).await???;
    assert!(!process_alive(pid));
    assert!(f.registry.devices()?.is_empty());
    assert_eq!(
        node.recent_results()
            .last()
            .unwrap()
            .process
            .as_ref()
            .unwrap()
            .finish,
        Finish::Cancelled
    );
    Ok(())
}
#[tokio::test]
async fn in_flight_and_expired_terminal_retries_preserve_state_without_execution() -> Result<()> {
    let mut f = Fixture::new(Provider::Claude)?;
    f.config.timeout_ms = 10_000;
    let node = f.node()?;
    let worker = node.clone();
    let (mut p, mut pt, d, mut dt) = f.pair().await?;
    let (stop, rx) = watch::channel(false);
    let server =
        tokio::spawn(
            async move { receiver::serve(&worker, d, &mut dt, &mut NoInjection, rx).await },
        );
    p.send(
        pt.as_mut(),
        &InnerMessage::AuthorizedCommand(command("inflight", "wait-tree")),
    )
    .await?;
    wait_file(f.root.path().join("child.pid")).await;
    let (mut retry, mut rt, rs, mut rd) = f.pair().await?;
    let (rstop, rx) = watch::channel(false);
    let worker = node.clone();
    let rserver =
        tokio::spawn(
            async move { receiver::serve(&worker, rs, &mut rd, &mut NoInjection, rx).await },
        );
    let mut duplicate = command("inflight", "different synthetic");
    duplicate.created_at = now_ms() - 40_000;
    duplicate.updated_at = duplicate.created_at;
    retry
        .send(rt.as_mut(), &InnerMessage::AuthorizedCommand(duplicate))
        .await?;
    let InnerMessage::TaskStatus(status) =
        tokio::time::timeout(Duration::from_secs(1), retry.receive(rt.as_mut())).await??
    else {
        panic!("status")
    };
    assert_eq!(status.execution_state, ExecutionState::Running);
    assert_eq!(f.calls().len(), 1);
    rstop.send(true)?;
    let _ = rserver.await?;
    stop.send(true)?;
    let _ = server.await?;
    let mut duplicate = command("inflight", "changed again");
    duplicate.created_at = now_ms() - 40_000;
    duplicate.updated_at = duplicate.created_at;
    assert_eq!(
        f.call(f.node()?, duplicate).await?.execution_state,
        ExecutionState::Cancelled
    );
    assert_eq!(f.calls().len(), 1);
    Ok(())
}

async fn relay_pair(
    f: &Fixture,
) -> Result<(
    Session,
    Box<dyn Transport>,
    Session,
    voiceremote_agents::transport::PacketTransport,
    tokio::task::JoinHandle<()>,
)> {
    use futures_util::{SinkExt, StreamExt};
    use voiceremote_core::transport::{RelayRoute, RelayTransport};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!("ws://{}", listener.local_addr()?);
    let bridge = tokio::spawn(async move {
        let mut first = tokio_tungstenite::accept_async(listener.accept().await.unwrap().0)
            .await
            .unwrap();
        let mut second = tokio_tungstenite::accept_async(listener.accept().await.unwrap().0)
            .await
            .unwrap();
        loop {
            tokio::select! {
                message=first.next()=>{
                    let Some(Ok(tokio_tungstenite::tungstenite::Message::Text(text)))=message else {break;};
                    if matches!(decode::<RelayFrame>(&text),Ok(RelayFrame::RelayCiphertext(_))) && second.send(tokio_tungstenite::tungstenite::Message::Text(text)).await.is_err(){break;}
                },
                message=second.next()=>{
                    let Some(Ok(tokio_tungstenite::tungstenite::Message::Text(text)))=message else {break;};
                    if matches!(decode::<RelayFrame>(&text),Ok(RelayFrame::RelayCiphertext(_))) && first.send(tokio_tungstenite::tungstenite::Message::Text(text)).await.is_err(){break;}
                }
            }
        }
    });
    let route = |sender: &str| RelayRoute {
        account: "test-account".into(),
        room: "test-room".into(),
        sender: sender.into(),
    };
    let (p, d) = tokio::join!(
        RelayTransport::connect_loopback(&endpoint, route("test-phone")),
        voiceremote_agents::transport::PacketTransport::connect_loopback(
            &endpoint,
            route("test-host")
        )
    );
    let (ps, p, ds, d) = f.pair_on(Box::new(p?), d?).await?;
    Ok((ps, p, ds, d, bridge))
}
#[tokio::test]
async fn same_relay_connection_reads_cancel_while_real_fake_tool_has_setsid() -> Result<()> {
    let mut f = Fixture::new(Provider::Claude)?;
    f.config.timeout_ms = 10_000;
    let node = f.node()?;
    let (mut p, mut pt, d, mut dt, bridge) = relay_pair(&f).await?;
    let (stop, rx) = watch::channel(false);
    let server =
        tokio::spawn(async move { receiver::serve(&node, d, &mut dt, &mut NoInjection, rx).await });
    p.send(
        pt.as_mut(),
        &InnerMessage::AuthorizedCommand(command("relay-task", "wait-tree")),
    )
    .await?;
    wait_file(f.root.path().join("child.pid")).await;
    let mut cancel = command("relay-cancel", "synthetic");
    cancel.immutable_task_payload = ToolCall::CancelTaskTool(CancelTaskTool {
        kind: CancelTaskToolKind::CancelTask,
        account_id: "test-account".into(),
        command_id: "relay-task".into(),
    });
    p.send(pt.as_mut(), &InnerMessage::AuthorizedCommand(cancel))
        .await?;
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let InnerMessage::TaskStatus(status) = p.receive(pt.as_mut()).await? {
                if status.command_id == "relay-task"
                    && status.execution_state == ExecutionState::Cancelled
                {
                    break Ok::<_, anyhow::Error>(());
                }
            }
        }
    })
    .await??;
    let pid: i32 = fs::read_to_string(f.root.path().join("child.pid"))?.parse()?;
    assert!(!process_alive(pid));
    stop.send(true)?;
    let _ = server.await?;
    bridge.abort();
    Ok(())
}
#[tokio::test]
async fn three_running_lan_tasks_leave_fourth_connection_for_control() -> Result<()> {
    let mut f = Fixture::new(Provider::Claude)?;
    f.config.timeout_ms = 10_000;
    for n in 1..4 {
        let mut project = f.config.projects[0].clone();
        project.project = format!("arm-{n}");
        project.sessions = vec![format!("test-session-{n}")];
        project.workspace = f.root.path().join(&project.project);
        fs::create_dir(&project.workspace)?;
        f.config.projects.push(project);
    }
    let (_p, _pt, _d, _dt) = f.pair().await?;
    let node = f.node()?;
    let listener = voiceremote_agents::transport::Listener::bind("127.0.0.1:0".parse()?).await?;
    let address = listener.address()?;
    let (stop, rx) = watch::channel(false);
    let identity = f.di.clone();
    let registry = f.registry.clone();
    let peer = registry.devices()?.remove(0);
    let server = tokio::spawn(async move {
        receiver::run_lan(
            node,
            listener,
            identity,
            registry,
            peer,
            "test-host".into(),
            Arc::new(|| Box::new(NoInjection)),
            rx,
        )
        .await
    });
    let mut connections = vec![];
    for n in 0..4 {
        let mut transport = LanTransport::connect(address).await?;
        let peer = f.phone_registry.devices()?.remove(0);
        let mut session = pairing::resume_initiate(
            &mut transport,
            &f.pi,
            &f.phone_registry,
            &peer,
            "test-phone",
        )
        .await?;
        let mut c = command(&format!("slot-{n}"), "wait-tree");
        if let ToolCall::DelegateTaskTool(t) = &mut c.immutable_task_payload {
            t.project_id = f.config.projects[n].project.clone();
            t.provider_session_id = Some(f.config.projects[n].sessions[0].clone());
        }
        c.provider_session_id = Some(f.config.projects[n].sessions[0].clone());
        session
            .send(&mut transport, &InnerMessage::AuthorizedCommand(c))
            .await?;
        let InnerMessage::TaskStatus(status) =
            tokio::time::timeout(Duration::from_millis(700), session.receive(&mut transport))
                .await??
        else {
            panic!("status")
        };
        if n < 3 {
            assert_eq!(status.execution_state, ExecutionState::Running);
            wait_file(f.config.projects[n].workspace.join("child.pid")).await;
        } else {
            assert_eq!(status.execution_state, ExecutionState::Failed);
            assert_eq!(status.outcome, Some(TaskStatusOutcome::Unavailable));
        }
        connections.push((session, transport));
    }
    let mut cancel = command("slot-cancel", "synthetic");
    cancel.immutable_task_payload = ToolCall::CancelTaskTool(CancelTaskTool {
        kind: CancelTaskToolKind::CancelTask,
        account_id: "test-account".into(),
        command_id: "slot-0".into(),
    });
    let (session, transport) = &mut connections[3];
    session
        .send(transport, &InnerMessage::AuthorizedCommand(cancel))
        .await?;
    let InnerMessage::TaskStatus(status) =
        tokio::time::timeout(Duration::from_millis(700), session.receive(transport)).await??
    else {
        panic!("status")
    };
    assert_eq!(status.outcome, Some(TaskStatusOutcome::Ok));
    let (session, transport) = &mut connections[0];
    let InnerMessage::TaskStatus(status) =
        tokio::time::timeout(Duration::from_secs(3), session.receive(transport)).await??
    else {
        panic!("status")
    };
    assert_eq!(status.execution_state, ExecutionState::Cancelled);
    stop.send(true)?;
    tokio::time::timeout(Duration::from_secs(5), server).await???;
    for project in &f.config.projects[..3] {
        let pid: i32 = fs::read_to_string(project.workspace.join("child.pid"))?.parse()?;
        assert!(!process_alive(pid));
    }
    Ok(())
}

#[tokio::test]
async fn claimed_key_without_receipt_is_nonterminal_even_after_expiry() -> Result<()> {
    let f = Fixture::new(Provider::Claude)?;
    let (_p, _pt, _d, _dt) = f.pair().await?;
    let peer = f.registry.devices()?.remove(0);
    assert!(f.registry.claim_command(&peer, "agent-key:uncertain")?);
    let mut c = command("uncertain", "synthetic");
    c.created_at = now_ms() - 40_000;
    c.updated_at = c.created_at;
    let result = f.call(f.node()?, c).await?;
    assert_eq!(result.execution_state, ExecutionState::Running);
    assert_eq!(result.outcome, Some(TaskStatusOutcome::Unavailable));
    assert!(f.calls().is_empty());
    Ok(())
}
#[tokio::test]
async fn cancelled_without_user_bus_is_unconfirmed_and_escaped_child_survives() -> Result<()> {
    let mut f = Fixture::new(Provider::Claude)?;
    f.config.timeout_ms = 10_000;
    fs::write(f.root.path().join("no-user-bus"), "")?;
    let node = f.node()?;
    let worker = node.clone();
    let (mut p, mut pt, d, mut dt) = f.pair().await?;
    let (stop, rx) = watch::channel(false);
    let server =
        tokio::spawn(
            async move { receiver::serve(&worker, d, &mut dt, &mut NoInjection, rx).await },
        );
    p.send(
        pt.as_mut(),
        &InnerMessage::AuthorizedCommand(command("uncontained", "wait-tree")),
    )
    .await?;
    wait_file(f.root.path().join("child.pid")).await;
    let mut cancel = command("uncontained-cancel", "synthetic");
    cancel.immutable_task_payload = ToolCall::CancelTaskTool(CancelTaskTool {
        kind: CancelTaskToolKind::CancelTask,
        account_id: "test-account".into(),
        command_id: "uncontained".into(),
    });
    p.send(pt.as_mut(), &InnerMessage::AuthorizedCommand(cancel))
        .await?;
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let InnerMessage::TaskStatus(status) = p.receive(pt.as_mut()).await? {
                if status.command_id == "uncontained"
                    && status.outcome == Some(TaskStatusOutcome::Unavailable)
                {
                    assert_eq!(status.execution_state, ExecutionState::Running);
                    break Ok::<_, anyhow::Error>(());
                }
            }
        }
    })
    .await??;
    let pid: i32 = fs::read_to_string(f.root.path().join("child.pid"))?.parse()?;
    assert!(process_alive(pid));
    assert_eq!(
        node.recent_results()
            .last()
            .unwrap()
            .process
            .as_ref()
            .unwrap()
            .finish,
        Finish::Unconfirmed
    );
    stop.send(true)?;
    let _ = server.await?;
    Ok(())
}

#[tokio::test]
async fn codex_failed_turn_and_error_without_completion_fail() -> Result<()> {
    let f = Fixture::new(Provider::Codex)?;
    for text in ["provider-failed", "error-only"] {
        let status = f.call(f.node()?, command(text, text)).await?;
        assert_eq!(status.execution_state, ExecutionState::Failed);
        assert_eq!(status.outcome, Some(TaskStatusOutcome::Error));
    }
    Ok(())
}

fn cloud_fixture(provider: CloudProvider) -> Result<Fixture> {
    use std::os::unix::fs::PermissionsExt;
    let mut f = Fixture::new(Provider::Cloud)?;
    f.config.projects[0].cloud = Some(CloudConfig {
        enabled: true,
        allow_read_only_override: false,
        provider,
        environment: "env_fake".into(),
        repository: "https://github.com/synthetic/project.git".into(),
        branch: "test-branch".into(),
    });
    f.config.projects[0].capability_profile = CapabilityProfile::WorkspaceWrite;
    let git = f.root.path().join("bin/git");
    fs::write(
        &git,
        r##"#!/usr/bin/python3
import sys,os
if os.path.exists('wrong-repo'): print('https://github.com/other/repo.git')
elif sys.argv[1] == 'config': print('https://github.com/synthetic/project.git')
else: print('test-branch')
"##,
    )?;
    fs::set_permissions(git, fs::Permissions::from_mode(0o700))?;
    Ok(f)
}

#[tokio::test]
async fn cloud_handoffs_are_separate_labelled_allowlisted_and_not_completion() -> Result<()> {
    // Run in an isolated child so actual populated secrets reach adapter construction
    // without process-global environment mutations racing other Rust tests.
    const SECRETS: &[&str] = &[
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "CODEX_HOME",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "LD_PRELOAD",
        "SSH_AUTH_SOCK",
        "HTTP_PROXY",
    ];
    if std::env::var("VR_TEST_POPULATED_ENV").as_deref() != Ok("1") {
        let mut child = std::process::Command::new(std::env::current_exe()?);
        child
            .args([
                "--exact",
                "cloud_handoffs_are_separate_labelled_allowlisted_and_not_completion",
                "--nocapture",
            ])
            .env("VR_TEST_POPULATED_ENV", "1");
        for key in SECRETS {
            child.env(key, "synthetic-scrub-sentinel");
        }
        assert!(child.status()?.success());
        return Ok(());
    }
    for key in SECRETS {
        assert_eq!(std::env::var(key)?.as_str(), "synthetic-scrub-sentinel");
    }
    for provider in [CloudProvider::Codex, CloudProvider::Claude] {
        let f = cloud_fixture(provider)?;
        let node = f.node()?;
        let prompt = "synthetic ; $(no-shell) --resume local-session";
        let status = f
            .call(node.clone(), command("cloud-handoff", prompt))
            .await?;
        assert_eq!(status.execution_state, ExecutionState::Running);
        assert_eq!(status.outcome, Some(TaskStatusOutcome::Unavailable));
        let results = node.recent_results();
        let result = results.last().unwrap().process.as_ref().unwrap();
        assert_eq!(result.finish, Finish::CloudSubmitted);
        assert!(!result.success);
        let receipt = result.cloud.as_ref().unwrap();
        assert_eq!(receipt.label, "cloud");
        assert_eq!(receipt.provider, Some(provider));
        assert!(!receipt.continues_local_session);
        assert!(!receipt.cancellation_supported);
        assert_eq!(
            receipt.task_id.as_deref(),
            Some(if provider == CloudProvider::Codex {
                "task_fake"
            } else {
                "session_fake"
            })
        );
        assert_eq!(
            receipt.state,
            if provider == CloudProvider::Codex {
                CloudState::Pending
            } else {
                CloudState::Submitted
            }
        );
        let calls = f.calls();
        let submit = calls.iter().find(|c| c["data"] == prompt).unwrap();
        let args = submit["argv"].as_array().unwrap();
        assert!(
            !args.iter().any(|a| a == prompt
                || a == "test-session"
                || a == "--resume"
                || a == "--continue")
        );
        assert!(args.iter().any(|a| a == "env_fake"));
        let env = submit["env"].as_array().unwrap();
        for key in [
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "CODEX_HOME",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "LD_PRELOAD",
            "SSH_AUTH_SOCK",
            "HTTP_PROXY",
        ] {
            assert!(!env.iter().any(|v| v == key));
        }
        // Same command ID is never submitted twice, even though cloud work is nonterminal.
        f.call(node.clone(), command("cloud-handoff", prompt))
            .await?;
        assert_eq!(f.calls().iter().filter(|c| c["data"] == prompt).count(), 1);
        let mut cancel = command("cancel-cloud", "synthetic");
        cancel.immutable_task_payload = ToolCall::CancelTaskTool(CancelTaskTool {
            kind: CancelTaskToolKind::CancelTask,
            account_id: "test-account".into(),
            command_id: "cloud-handoff".into(),
        });
        f.call(node.clone(), cancel).await?;
        let results = node.recent_results();
        let cancelled = results.last().unwrap().process.as_ref().unwrap();
        assert_eq!(cancelled.finish, Finish::CancelUnsupported);
        assert_eq!(cancelled.cloud.as_ref().unwrap().label, "cloud");
        assert_eq!(cancelled.cloud.as_ref().unwrap().task_id, receipt.task_id);
    }
    Ok(())
}

#[tokio::test]
async fn cloud_disabled_and_project_repository_allowlists_fail_before_submit() -> Result<()> {
    let mut f = cloud_fixture(CloudProvider::Codex)?;
    f.config.projects[0].cloud.as_mut().unwrap().enabled = false;
    let node = f.node()?;
    f.call(node.clone(), command("disabled-cloud", "synthetic"))
        .await?;
    let result = node.recent_results().pop().unwrap().process.unwrap();
    assert_eq!(result.finish, Finish::NotConfigured);
    assert_eq!(result.cloud.unwrap().label, "cloud");
    assert!(f.calls().is_empty());
    f.config.projects[0].cloud.as_mut().unwrap().enabled = true;
    fs::write(f.root.path().join("wrong-repo"), "")?;
    let node = f.node()?;
    f.call(node.clone(), command("repo-denied", "synthetic"))
        .await?;
    assert_eq!(
        node.recent_results().pop().unwrap().process.unwrap().finish,
        Finish::NotConfigured
    );
    assert!(f.calls().is_empty());
    fs::remove_file(f.root.path().join("wrong-repo"))?;
    let mut unknown = command("project-denied", "synthetic");
    if let ToolCall::DelegateTaskTool(ref mut task) = unknown.immutable_task_payload {
        task.project_id = "unknown-project".into();
    }
    assert_eq!(
        f.call(f.node()?, unknown).await?.outcome,
        Some(TaskStatusOutcome::Denied)
    );
    assert!(f.calls().is_empty());
    // enabled defaults false even when the rest of the cloud table is supplied.
    let config: CloudConfig = toml::from_str(
        "provider='codex'\nenvironment='env_fake'\nrepository='https://github.com/synthetic/project.git'\nbranch='main'",
    )?;
    assert!(!config.enabled);
    Ok(())
}

#[tokio::test]
async fn cloud_failures_never_invent_ids_success_or_local_continuity() -> Result<()> {
    for provider in [CloudProvider::Claude, CloudProvider::Codex] {
        let f = cloud_fixture(provider)?;
        for (index, prompt) in [
            "nonzero",
            "malformed",
            "empty-success",
            "wrong-session",
            "claude-json",
        ]
        .into_iter()
        .enumerate()
        {
            let node = f.node()?;
            f.call(node.clone(), command(&format!("failure-{index}"), prompt))
                .await?;
            let result = node.recent_results().pop().unwrap().process.unwrap();
            // claude-json is also deliberately rejected for creation; JSON documented
            // for follow-ups does not prove a new cloud session was created.
            assert!(!result.success);
            let receipt = result.cloud.unwrap();
            assert_eq!(receipt.label, "cloud");
            assert!(receipt.task_id.is_none());
            assert!(!receipt.continues_local_session);
            assert!(matches!(
                result.finish,
                Finish::CloudFailed | Finish::Unconfirmed
            ));
        }
    }
    Ok(())
}

#[tokio::test]
async fn codex_cloud_status_is_not_inferred_from_cli_exit_code() -> Result<()> {
    let f = cloud_fixture(CloudProvider::Codex)?;
    for (index, (marker, expected)) in [
        ("READY", CloudState::Ready),
        ("APPLIED", CloudState::Applied),
        ("ERROR", CloudState::Failed),
        ("BROKEN", CloudState::Unknown),
    ]
    .into_iter()
    .enumerate()
    {
        fs::write(f.root.path().join("cloud-status"), marker)?;
        let node = f.node()?;
        f.call(
            node.clone(),
            command(&format!("status-{index}"), "synthetic"),
        )
        .await?;
        let result = node.recent_results().pop().unwrap().process.unwrap();
        assert_eq!(result.cloud.unwrap().state, expected);
        assert!(!result.success); // ready/applied do not prove the delegated task's success.
    }
    Ok(())
}

#[tokio::test]
async fn computer_ui_action_is_explicitly_unsupported_without_spawning() -> Result<()> {
    let f = Fixture::new(Provider::Claude)?;
    let node = f.node()?;
    let mut action = command("computer-use-deferred", "synthetic");
    action.immutable_task_payload = ToolCall::OpenResourceTool(OpenResourceTool {
        kind: OpenResourceToolKind::OpenResource,
        account_id: "test-account".into(),
        device_id: "test-host".into(),
        resource_uri: "https://example.com".into(),
    });
    assert_eq!(
        f.call(node.clone(), action).await?.outcome,
        Some(TaskStatusOutcome::Unavailable)
    );
    assert_eq!(
        node.recent_results().pop().unwrap().process.unwrap().finish,
        Finish::UnsupportedAction
    );
    assert!(f.calls().is_empty());
    Ok(())
}

#[tokio::test]
async fn cloud_timeout_and_missing_cli_remain_honest_and_labelled() -> Result<()> {
    let mut f = cloud_fixture(CloudProvider::Codex)?;
    f.config.timeout_ms = 200;
    let node = f.node()?;
    f.call(node.clone(), command("cloud-timeout", "timeout"))
        .await?;
    let result = node.recent_results().pop().unwrap().process.unwrap();
    assert_eq!(result.finish, Finish::Unconfirmed);
    let receipt = result.cloud.unwrap();
    assert_eq!(receipt.state, CloudState::Unknown);
    assert_eq!(receipt.label, "cloud");
    assert!(receipt.task_id.is_none());
    assert!(!receipt.cancellation_supported);
    // systemd-run can start successfully even if the CLI itself is missing.
    // Exercise direct spawn failure without the optional user bus.
    fs::write(f.root.path().join("no-user-bus"), "")?;
    fs::remove_file(f.root.path().join("bin/codex"))?;
    let node = f.node()?;
    f.call(node.clone(), command("cloud-missing-cli", "synthetic"))
        .await?;
    let result = node.recent_results().pop().unwrap().process.unwrap();
    assert_eq!(result.finish, Finish::SpawnFailed);
    assert_eq!(result.cloud.unwrap().label, "cloud");
    assert!(!result.success);
    Ok(())
}

#[tokio::test]
async fn cloud_provider_id_cannot_equal_the_routing_session_id() -> Result<()> {
    let mut f = cloud_fixture(CloudProvider::Codex)?;
    f.config.projects[0].sessions = vec!["task_fake".into()];
    let mut task = command("cloud-no-continuity", "synthetic");
    task.provider_session_id = Some("task_fake".into());
    if let ToolCall::DelegateTaskTool(ref mut payload) = task.immutable_task_payload {
        payload.provider_session_id = task.provider_session_id.clone();
    }
    let node = f.node()?;
    f.call(node.clone(), task).await?;
    let result = node.recent_results().pop().unwrap().process.unwrap();
    assert_eq!(result.finish, Finish::Unconfirmed);
    assert!(result.cloud.unwrap().task_id.is_none());
    assert!(
        !f.calls()[0]["argv"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "task_fake")
    );
    Ok(())
}

#[test]
fn cloud_config_rejects_unsafe_environment_repository_and_local_provider() -> Result<()> {
    let mut f = cloud_fixture(CloudProvider::Codex)?;
    for (field, value) in [
        ("environment", "--bad"),
        ("repository", "https://other.example/synthetic/repo"),
        ("branch", "--upload"),
        ("branch", "main..other"),
    ] {
        let mut config = f.config.clone();
        let cloud = config.projects[0].cloud.as_mut().unwrap();
        match field {
            "environment" => cloud.environment = value.into(),
            "repository" => cloud.repository = value.into(),
            _ => cloud.branch = value.into(),
        }
        assert!(
            AgentNode::new(
                config,
                CliAdapter::default(),
                Arc::new(FileKeyStore::new(f.root.path().join("config-tests"))?)
            )
            .is_err()
        );
    }
    f.config.projects[0].provider = Provider::Codex;
    assert!(f.node().is_err());
    Ok(())
}

#[tokio::test]
async fn claude_creation_uses_session_id_never_title() -> Result<()> {
    let f = cloud_fixture(CloudProvider::Claude)?;
    for (index, prompt) in ["id-shaped-title", "synthetic", "duplicate-id"]
        .into_iter()
        .enumerate()
    {
        let node = f.node()?;
        f.call(node.clone(), command(&format!("claude-id-{index}"), prompt))
            .await?;
        let result = node.recent_results().pop().unwrap().process.unwrap();
        let receipt = result.cloud.unwrap();
        if prompt == "synthetic" {
            assert_eq!(receipt.task_id.as_deref(), Some("session_fake"));
            assert_eq!(result.finish, Finish::CloudSubmitted);
        } else {
            assert!(
                receipt.task_id.is_none(),
                "title or duplicate Session ID accepted"
            );
            assert_eq!(result.finish, Finish::Unconfirmed);
        }
    }
    Ok(())
}

#[tokio::test]
async fn cloud_read_only_requires_explicit_permission_override() -> Result<()> {
    for provider in [CloudProvider::Codex, CloudProvider::Claude] {
        let mut f = cloud_fixture(provider)?;
        f.config.projects[0].capability_profile = CapabilityProfile::ReadOnly;
        let node = f.node()?;
        f.call(node.clone(), command("readonly-denied", "synthetic"))
            .await?;
        let process = node.recent_results().pop().unwrap().process.unwrap();
        assert_eq!(process.finish, Finish::UnsupportedAction);
        assert_eq!(
            serde_json::to_value(process.cloud.unwrap())?["permissions_label"],
            "read-only refused"
        );
        assert!(f.calls().is_empty());
        let provider = if provider == CloudProvider::Codex {
            "codex"
        } else {
            "claude"
        };
        f.config.projects[0].cloud = Some(toml::from_str(&format!(
            "enabled=true\nprovider='{provider}'\nenvironment='env_fake'\nrepository='https://github.com/synthetic/project.git'\nbranch='test-branch'\nallow_read_only_override=true"
        ))?);
        let node = f.node()?;
        f.call(node.clone(), command("readonly-override", "synthetic"))
            .await?;
        let process = node.recent_results().pop().unwrap().process.unwrap();
        assert_eq!(process.finish, Finish::CloudSubmitted);
        assert_eq!(
            serde_json::to_value(process.cloud.unwrap())?["permissions_label"],
            "read-only override: provider environment permissions"
        );
    }
    Ok(())
}

#[tokio::test]
async fn cloud_launch_cancel_signals_launcher_and_crash_receipt_is_unknown() -> Result<()> {
    for restarted in [false, true] {
        let mut f = cloud_fixture(CloudProvider::Codex)?;
        f.config.timeout_ms = 10_000;
        let node = f.node()?;
        let (mut p, mut pt, d, mut dt) = f.pair().await?;
        let (stop, rx) = watch::channel(false);
        let worker = node.clone();
        let server = tokio::spawn(async move {
            receiver::serve(&worker, d, &mut dt, &mut NoInjection, rx).await
        });
        p.send(
            pt.as_mut(),
            &InnerMessage::AuthorizedCommand(command("cloud-launch", "wait-tree")),
        )
        .await?;
        wait_file(f.root.path().join("child.pid")).await;
        let pid: i32 = fs::read_to_string(f.root.path().join("child.pid"))?.parse()?;
        let cancel_node = if restarted { f.node()? } else { node.clone() };
        let mut cancel = command("cancel-cloud-launch", "synthetic");
        cancel.immutable_task_payload = ToolCall::CancelTaskTool(CancelTaskTool {
            kind: CancelTaskToolKind::CancelTask,
            account_id: "test-account".into(),
            command_id: "cloud-launch".into(),
        });
        f.call(cancel_node.clone(), cancel).await?;
        let process = cancel_node.recent_results().pop().unwrap().process.unwrap();
        assert_eq!(process.finish, Finish::CancelUnsupported);
        assert_eq!(process.cloud.unwrap().state, CloudState::Unknown);
        if !restarted {
            tokio::time::timeout(Duration::from_secs(3), async {
                loop {
                    if let InnerMessage::TaskStatus(status) = p.receive(pt.as_mut()).await? {
                        if status.command_id == "cloud-launch" && status.outcome.is_some() {
                            break Ok::<_, anyhow::Error>(());
                        }
                    }
                }
            })
            .await??;
            assert!(
                !process_alive(pid),
                "cancel did not signal and stop the launcher tree"
            );
        }
        stop.send(true)?;
        server.await??;
    }
    Ok(())
}

#[tokio::test]
async fn authenticated_inventory_and_resource_handoff_bind_preview_and_query_without_resend()
-> Result<()> {
    use base64::Engine;
    use sha2::{Digest, Sha256};
    let f = Fixture::new(Provider::Claude)?;
    let node = f.node()?;
    let (mut phone, mut transport, desktop, mut desktop_transport) = f.pair().await?;
    let (stop, receive) = watch::channel(false);
    let serve = tokio::spawn(async move {
        receiver::serve(
            &node,
            desktop,
            &mut desktop_transport,
            &mut NoInjection,
            receive,
        )
        .await
    });
    phone
        .send(
            transport.as_mut(),
            &InnerMessage::AgentInventoryRequest(AgentInventoryRequest {
                kind: AgentInventoryRequestKind::AgentInventoryRequest,
                account_id: "test-account".into(),
                request_id: "query".into(),
            }),
        )
        .await?;
    let InnerMessage::AgentInventory(inventory) = phone.receive(transport.as_mut()).await? else {
        anyhow::bail!("inventory required")
    };
    assert_eq!(inventory.authenticated_actor, "test-owner");
    assert_eq!(inventory.sessions.len(), 1);
    let identity = inventory.sessions[0].clone();
    assert_eq!(identity.project_id, "arm-design");
    assert_eq!(identity.workspace, f.root.path().to_string_lossy());
    let mut command = command("resource-envelope", "unused");
    command.provider_session_id = None;
    command.immutable_task_payload = ToolCall::OpenResourceTool(OpenResourceTool {
        kind: OpenResourceToolKind::OpenResource,
        account_id: "test-account".into(),
        device_id: "test-host".into(),
        resource_uri: "https://example.invalid/synthetic".into(),
    });
    let expiry = now_ms() + 20_000;
    let bytes = serde_json::to_vec(&serde_json::json!({ "tool": command.immutable_task_payload,
        "account": command.account_id, "actor": command.authenticated_actor, "device": command.destination_id,
        "project": "arm-design", "risk": "sensitive", "expiresAt": expiry, "request": command.candidate_id, "policy": command.policy_version }))?;
    command.payload_hash = hex::encode(Sha256::digest(&bytes));
    let envelope = AgentDispatch {
        kind: AgentDispatchKind::AgentDispatch,
        account_id: command.account_id.clone(),
        command: command.clone(),
        session: identity,
        immutable_preview: base64::engine::general_purpose::STANDARD.encode(bytes),
        expires_at: expiry,
    };
    let mut wrong = envelope.clone();
    wrong.session.workspace.push_str("-changed");
    phone
        .send(transport.as_mut(), &InnerMessage::AgentDispatch(wrong))
        .await?;
    let InnerMessage::TaskStatus(denied) = phone.receive(transport.as_mut()).await? else {
        anyhow::bail!("status required")
    };
    assert_eq!(denied.outcome, Some(TaskStatusOutcome::Denied));
    assert!(f.calls().is_empty());
    phone
        .send(
            transport.as_mut(),
            &InnerMessage::AgentDispatch(envelope.clone()),
        )
        .await?;
    loop {
        let InnerMessage::TaskStatus(status) = phone.receive(transport.as_mut()).await? else {
            anyhow::bail!("status required")
        };
        if status.execution_state != ExecutionState::Running {
            assert_eq!(status.execution_state, ExecutionState::Succeeded);
            break;
        }
    }
    let mut expired = envelope;
    expired.expires_at = 0;
    phone
        .send(transport.as_mut(), &InnerMessage::AgentDispatch(expired))
        .await?;
    let InnerMessage::TaskStatus(replay) = phone.receive(transport.as_mut()).await? else {
        anyhow::bail!("receipt required")
    };
    assert_eq!(replay.execution_state, ExecutionState::Succeeded);
    phone
        .send(
            transport.as_mut(),
            &InnerMessage::AgentTaskQuery(AgentTaskQuery {
                kind: AgentTaskQueryKind::AgentTaskQuery,
                account_id: "test-account".into(),
                command_id: command.command_id,
            }),
        )
        .await?;
    let InnerMessage::TaskStatus(status) = phone.receive(transport.as_mut()).await? else {
        anyhow::bail!("query required")
    };
    assert_eq!(status.execution_state, ExecutionState::Succeeded);
    assert_eq!(f.calls().len(), 1);
    assert_eq!(
        f.calls()[0]["data"],
        "Open this exact resource using your installed application's available tools: https://example.invalid/synthetic"
    );
    stop.send(true)?;
    serve.await??;
    Ok(())
}
