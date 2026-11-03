use std::process::Command;
fn cli() -> Command {
    Command::new(env!("CARGO_BIN_EXE_voiceremote"))
}
#[test]
fn help_exposes_required_commands() {
    let output = cli().arg("--help").output().unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    for command in ["pair", "devices", "revoke", "run", "dictate"] {
        assert!(text.contains(command));
    }
}
#[test]
fn pair_requires_explicit_mode_and_rejects_conflicting_transports() {
    assert!(
        !cli()
            .args([
                "pair",
                "--account",
                "synthetic-account",
                "--listen",
                "127.0.0.1:0"
            ])
            .status()
            .unwrap()
            .success()
    );
    assert!(
        !cli()
            .args([
                "pair",
                "--qr",
                "--account",
                "synthetic-account",
                "--listen",
                "127.0.0.1:0",
                "--relay",
                "wss://example.invalid"
            ])
            .env_remove("VOICEREMOTE_RELAY_URL")
            .status()
            .unwrap()
            .success()
    );
    assert!(
        !cli()
            .args(["pair", "--qr", "--code", "--account", "synthetic-account"])
            .status()
            .unwrap()
            .success()
    );
}
#[test]
fn dictate_toggle_fails_without_a_running_receiver() {
    let dir = tempfile::tempdir().unwrap();
    let output = cli()
        .arg("--state-dir")
        .arg(dir.path().join("missing"))
        .args(["dictate", "toggle"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!String::from_utf8_lossy(&output.stdout).contains("stub"));
}
#[cfg(unix)]
#[tokio::test]
async fn dictate_toggle_cli_sends_fixed_request_to_user_socket() -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::UnixListener,
    };
    let dir = tempfile::tempdir()?;
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700))?;
    let socket = UnixListener::bind(dir.path().join("control.sock"))?;
    let server = tokio::spawn(async move {
        let (mut stream, _) = socket.accept().await?;
        let mut request = [0; 7];
        stream.read_exact(&mut request).await?;
        assert_eq!(&request, b"toggle\n");
        stream.write_all(b"sent\n").await?;
        Ok::<_, anyhow::Error>(())
    });
    let output = tokio::process::Command::new(env!("CARGO_BIN_EXE_voiceremote"))
        .arg("--state-dir")
        .arg(dir.path())
        .args(["dictate", "toggle"])
        .output()
        .await?;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("phone confirmation pending"));
    server.await??;
    Ok(())
}

/// Exercise actual stdin confirmation, persisted enrollment and remote revoke.
/// Only synthetic identities in temporary private storage.
#[cfg(unix)]
#[tokio::test]
async fn cli_code_pair_requires_both_confirmations_then_remote_revoke_exits() -> anyhow::Result<()>
{
    use std::{process::Stdio, sync::Arc, time::Duration};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use voiceremote_core::{
        pairing::{self, SystemClock},
        protocol::*,
        storage::{FileKeyStore, Identity, Registry},
        transport::{LanTransport, Transport},
    };
    let directory = tempfile::tempdir()?;
    let root = directory.path().join("desktop");
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_voiceremote"))
        .arg("--state-dir")
        .arg(&root)
        .args([
            "pair",
            "--code",
            "--account",
            "synthetic-account",
            "--device",
            "synthetic-receiver",
            "--listen",
            "127.0.0.1:0",
        ])
        .env_remove("VOICEREMOTE_RELAY_URL")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::piped())
        .kill_on_drop(true)
        .spawn()?;
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut output = BufReader::new(child.stdout.take().unwrap()).lines();
        let mut errors = BufReader::new(child.stderr.take().unwrap()).lines();
        let payload: PairingPayload = decode(
            &output
                .next_line()
                .await?
                .ok_or_else(|| anyhow::anyhow!("missing code"))?,
        )
        .map_err(anyhow::Error::msg)?;
        // The same validated payload is accepted by the actual QR renderer.
        qrcode::QrCode::new(encode(&payload).map_err(anyhow::Error::msg)?.as_bytes())?;
        let announcement = errors
            .next_line()
            .await?
            .ok_or_else(|| anyhow::anyhow!("missing listener"))?;
        let address = announcement
            .strip_prefix("LAN pairing listener: ")
            .and_then(|s| s.split(' ').next())
            .ok_or_else(|| anyhow::anyhow!("bad listener announcement"))?
            .parse()?;
        let mut transport = LanTransport::connect(address).await?;
        let identity = Identity::generate()?;
        let mut pending =
            pairing::initiate(&mut transport, &identity, &payload, &SystemClock).await?;
        let phrase = pending.phrase();
        // No enrollment exists before the trusted local confirmation.
        let desktop = Registry::new(Arc::new(FileKeyStore::new(&root)?));
        assert!(desktop.devices()?.is_empty());
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(format!("{phrase}\n").as_bytes())
            .await?;
        let info = DeviceInfo {
            kind: DeviceInfoKind::DeviceInfo,
            account_id: "synthetic-account".into(),
            device_id: "phone".into(),
            display_name: "Synthetic phone".into(),
            platform: DeviceInfoPlatform::Ios,
            role: DeviceInfoRole::TextReceiver,
            capabilities: vec![Capability::ReceiveText],
        };
        pending.confirm_local(&mut transport, &phrase, info).await?;
        pending.receive_confirmation(&mut transport).await?;
        assert!(
            output
                .next_line()
                .await?
                .unwrap()
                .starts_with("Paired phone (")
        );
        assert_eq!(desktop.devices()?.len(), 1);
        let phone_store = Arc::new(FileKeyStore::new(directory.path().join("phone"))?);
        let session = pending.finish(Registry::new(phone_store))?;
        assert_eq!(
            desktop.local_info()?.unwrap().device_id,
            "synthetic-receiver"
        );
        let phone_registry = session.registry().clone();
        let phone_peer = session.peer().clone();
        assert!(
            Command::new("kill")
                .args(["-INT", &child.id().unwrap().to_string()])
                .status()?
                .success()
        );
        assert!(child.wait().await?.success());
        let mismatched = cli()
            .arg("--state-dir")
            .arg(&root)
            .args([
                "run",
                "--headless",
                "--account",
                "synthetic-account",
                "--device",
                "wrong-name",
                "--listen",
                "127.0.0.1:0",
            ])
            .env_remove("VOICEREMOTE_RELAY_URL")
            .output()?;
        assert!(!mismatched.status.success());
        assert!(String::from_utf8(mismatched.stderr)?.contains("persisted pairing identity"));
        // A silent first connection cannot block actual SIGINT cancellation.
        let mut idle = tokio::process::Command::new(env!("CARGO_BIN_EXE_voiceremote"))
            .arg("--state-dir")
            .arg(&root)
            .args([
                "run",
                "--headless",
                "--account",
                "synthetic-account",
                "--listen",
                "127.0.0.1:0",
            ])
            .env_remove("VOICEREMOTE_RELAY_URL")
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let mut idle_errors = BufReader::new(idle.stderr.take().unwrap()).lines();
        let address = idle_errors
            .next_line()
            .await?
            .unwrap()
            .strip_prefix("LAN receiver listener: ")
            .unwrap()
            .parse()?;
        let _silent = LanTransport::connect(address).await?;
        assert!(
            Command::new("kill")
                .args(["-INT", &idle.id().unwrap().to_string()])
                .status()?
                .success()
        );
        assert!(idle.wait().await?.success());
        let mut restarted = tokio::process::Command::new(env!("CARGO_BIN_EXE_voiceremote"))
            .arg("--state-dir")
            .arg(&root)
            .args([
                "run",
                "--headless",
                "--account",
                "synthetic-account",
                "--listen",
                "127.0.0.1:0",
            ])
            .env_remove("VOICEREMOTE_RELAY_URL")
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let mut errors = BufReader::new(restarted.stderr.take().unwrap()).lines();
        let address = errors
            .next_line()
            .await?
            .unwrap()
            .strip_prefix("LAN receiver listener: ")
            .unwrap()
            .parse()?;
        let mut transport = LanTransport::connect(address).await?;
        let mut session = pairing::resume_initiate(
            &mut transport,
            &identity,
            &phone_registry,
            &phone_peer,
            "phone",
        )
        .await?;
        session
            .send(
                &mut transport,
                &InnerMessage::Revoke(Revoke {
                    kind: RevokeKind::Revoke,
                    account_id: "synthetic-account".into(),
                    device_id: "synthetic-receiver".into(),
                    command_id: "synthetic-revoke".into(),
                    idempotency_key: "synthetic-revoke".into(),
                    revoked_at: 1,
                }),
            )
            .await?;
        assert!(restarted.wait().await?.success());
        assert!(desktop.devices()?.is_empty());
        let _ = transport.close().await;
        Ok::<_, anyhow::Error>(())
    })
    .await??;
    Ok(())
}

#[cfg(unix)]
#[test]
fn revoke_unknown_is_an_error_and_device_name_is_accepted() -> anyhow::Result<()> {
    use std::sync::Arc;
    use voiceremote_core::{
        protocol::*,
        storage::{FileKeyStore, Identity, Registry},
    };
    let directory = tempfile::tempdir()?;
    let root = directory.path().join("keys");
    let registry = Registry::new(Arc::new(FileKeyStore::new(&root)?));
    let run = |query: &str| {
        cli()
            .arg("--state-dir")
            .arg(&root)
            .args(["revoke", query])
            .output()
            .unwrap()
    };
    assert!(
        !run("unknown-device").status.success(),
        "unknown revocation must fail"
    );
    let peer = registry.enroll(
        Identity::generate()?.public,
        "synthetic-room".into(),
        DeviceInfo {
            kind: DeviceInfoKind::DeviceInfo,
            account_id: "synthetic-account".into(),
            device_id: "synthetic-phone".into(),
            display_name: "Synthetic phone".into(),
            platform: DeviceInfoPlatform::Ios,
            role: DeviceInfoRole::TextReceiver,
            capabilities: vec![Capability::ReceiveText],
        },
    )?;
    assert!(run("Synthetic phone").status.success());
    assert!(
        registry.peer(&peer.id)?.is_none(),
        "name must resolve to actual enrollment"
    );
    assert!(!run(&peer.id).status.success());
    let by_id = registry.enroll(
        Identity::generate()?.public,
        "synthetic-room".into(),
        peer.info,
    )?;
    assert!(run(&by_id.id).status.success());
    assert!(registry.peer(&by_id.id)?.is_none());
    Ok(())
}
