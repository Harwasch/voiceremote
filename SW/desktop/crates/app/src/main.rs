use anyhow::{Result, bail, ensure};
use clap::{Parser, Subcommand};
use std::{net::SocketAddr, path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::watch;
use voiceremote_core::{
    TextInjector,
    pairing::{self, Offer, SystemClock},
    protocol::*,
    receiver::InjectorFactory,
    relay::{RelayClient, RelayIdentity},
    storage::{FileKeyStore, Identity, KeyStore, ReceiverLease, Registry},
    transport::{RelayRoute, Transport},
};
#[cfg(any(windows, target_os = "linux", test))]
mod desktop_receiver;
#[cfg(any(windows, target_os = "linux", test))]
mod desktop_transport;
#[cfg(any(windows, target_os = "linux"))]
use desktop_receiver as receiver;
#[cfg(any(windows, target_os = "linux"))]
use desktop_transport::{LanListener, RelayTransport};
#[cfg(not(any(windows, target_os = "linux")))]
use voiceremote_core::{
    receiver,
    transport::{LanListener, RelayTransport},
};
fn default_state_dir() -> PathBuf {
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
#[derive(Parser)]
#[command(
    name = "voiceremote",
    version,
    about = "Voice Control Fabric desktop receiver"
)]
struct Cli {
    #[arg(long,env="VOICEREMOTE_STATE_DIR",default_value_os_t=default_state_dir())]
    state_dir: PathBuf,
    #[arg(long)]
    keychain: bool,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    Pair {
        #[arg(long, conflicts_with = "code", required_unless_present = "code")]
        qr: bool,
        #[arg(long, conflicts_with = "qr")]
        code: bool,
        #[arg(long, env = "VOICEREMOTE_ACCOUNT")]
        account: String,
        #[arg(long)]
        device: Option<String>,
        #[arg(long, conflicts_with = "relay")]
        listen: Option<SocketAddr>,
        /// Relay origin, e.g. https://relay.example. Requires provisioned room.
        #[arg(long, env = "VOICEREMOTE_RELAY_URL")]
        relay: Option<String>,
        #[arg(long)]
        room: Option<String>,
        /// Prospective phone ID and Ed25519 key from a trusted exchange.
        #[arg(long)]
        phone_device: Option<String>,
        #[arg(long)]
        phone_relay_key: Option<String>,
    },
    Devices,
    Revoke {
        device: String,
        #[arg(long, env = "VOICEREMOTE_RELAY_URL")]
        relay: Option<String>,
    },
    Run {
        #[arg(long)]
        headless: bool,
        /// Owner-edited agent project/session allowlist (headless only).
        #[arg(long, requires = "headless")]
        agents_config: Option<PathBuf>,
        #[arg(long, env = "VOICEREMOTE_ACCOUNT")]
        account: String,
        /// Optional assertion; receiver uses the identity persisted at pairing.
        #[arg(long)]
        device: Option<String>,
        #[arg(long, conflicts_with = "relay")]
        listen: Option<SocketAddr>,
        #[arg(long, env = "VOICEREMOTE_RELAY_URL")]
        relay: Option<String>,
        #[arg(long)]
        peer: Option<String>,
    },
    /// Print only the public Ed25519 relay key for trusted provisioning.
    RelayKey {
        #[arg(long)]
        device: Option<String>,
        #[arg(long, env = "VOICEREMOTE_ACCOUNT")]
        account: String,
    },
    /// Privileged operator command; never runs implicitly during ordinary pairing.
    RelayBootstrap {
        #[arg(long)]
        device: Option<String>,
        #[arg(long, env = "VOICEREMOTE_ACCOUNT")]
        account: String,
        #[arg(long)]
        room: String,
        #[arg(long, env = "VOICEREMOTE_RELAY_URL")]
        relay: String,
    },
    Dictate {
        #[command(subcommand)]
        command: DictateCommand,
    },
}
#[derive(Subcommand)]
enum DictateCommand {
    Toggle,
}
struct UnavailableInjector;
impl TextInjector for UnavailableInjector {
    fn insert_text(&mut self, _: &str) -> Result<()> {
        Err(voiceremote_core::InsertionFailure::NotStarted.into())
    }
}
#[cfg(windows)]
struct WindowsAppInjector;
#[cfg(windows)]
impl voiceremote_core::TextInjector for WindowsAppInjector {
    fn insert_text(&mut self, text: &str) -> Result<()> {
        let result = voiceremote_core::TextInjector::insert_text(
            &mut voiceremote_inject_windows::WindowsInjector,
            text,
        );
        if let Err(error) = &result {
            // Native errors contain fixed diagnostics and OS error codes only.
            eprintln!("Windows dictation insertion failed: {error:#}");
        }
        result
    }
    fn insert_text_async<'a>(
        &'a mut self,
        text: &'a str,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send + 'a>> {
        Box::pin(async move {
            let result = voiceremote_core::TextInjector::insert_text_async(
                &mut voiceremote_inject_windows::WindowsInjector,
                text,
            )
            .await;
            if let Err(error) = &result {
                eprintln!("Windows dictation insertion failed: {error:#}");
            }
            result
        })
    }
}
fn injector_factory(state_dir: &std::path::Path, headless: bool) -> InjectorFactory {
    if headless {
        #[cfg(any(windows, target_os = "linux"))]
        desktop_receiver::set_focus_sampler(Arc::new(|| (false, 0)));
        return Arc::new(|| Box::new(UnavailableInjector));
    }
    #[cfg(target_os = "linux")]
    {
        let injector = voiceremote_inject_linux::LinuxInjector::new(state_dir.to_path_buf());
        let sampler = injector.clone();
        desktop_receiver::set_focus_sampler(Arc::new(move || {
            let snapshot = sampler.focus_snapshot();
            (snapshot.text_field_focused, snapshot.last_activity_at)
        }));
        Arc::new(move || Box::new(injector.clone()))
    }
    #[cfg(windows)]
    {
        let _ = state_dir;
        desktop_receiver::set_focus_sampler(Arc::new(|| {
            let snapshot = voiceremote_inject_windows::focus_snapshot();
            (snapshot.text_field_focused, snapshot.last_activity_at)
        }));
        Arc::new(|| Box::new(WindowsAppInjector))
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = state_dir;
        Arc::new(|| Box::new(UnavailableInjector))
    }
}
fn store(cli: &Cli) -> Result<Arc<dyn KeyStore>> {
    if cli.keychain {
        #[cfg(feature = "os-keychain")]
        return Ok(Arc::new(voiceremote_core::storage::OsKeyStore {
            service: "voiceremote-desktop".into(),
        }));
        #[cfg(not(feature = "os-keychain"))]
        bail!("rebuild with --features os-keychain");
    }
    Ok(Arc::new(FileKeyStore::new(&cli.state_dir)?))
}
fn info(account: &str, device: &str) -> DeviceInfo {
    DeviceInfo {
        kind: DeviceInfoKind::DeviceInfo,
        account_id: account.into(),
        device_id: device.into(),
        display_name: device.into(),
        platform: if cfg!(windows) {
            DeviceInfoPlatform::Windows
        } else {
            DeviceInfoPlatform::Linux
        },
        role: DeviceInfoRole::TextReceiver,
        capabilities: vec![Capability::ReceiveText],
    }
}
fn pairing_id(registry: &Registry, requested: Option<String>) -> Result<String> {
    if registry.local_info()?.is_some() {
        return registry.local_id(requested.as_deref());
    }
    Ok(requested.unwrap_or_else(|| "desktop".into()))
}
fn relay_client(
    origin: &str,
    account: String,
    room: String,
    device: String,
    keys: &dyn KeyStore,
) -> Result<RelayClient> {
    RelayClient::new(
        origin,
        RelayRoute {
            account,
            room,
            sender: device,
        },
        RelayIdentity::load_or_create(keys)?,
    )
}
async fn read_confirmation(stop: watch::Receiver<bool>) -> Result<String> {
    // A detached std thread does not hold Tokio runtime shutdown hostage on Ctrl-C.
    let (send, receive) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let result = (|| -> Result<String> {
            let mut line = String::new();
            std::io::stdin().read_line(&mut line)?;
            Ok(line.trim().into())
        })();
        let _ = send.send(result);
    });
    tokio::select! {result=receive=>result?,_=receiver::stopped(stop)=>bail!("pairing stopped")}
}
#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    #[cfg(target_os = "linux")]
    let _ = tracing_subscriber::fmt()
        .with_env_filter("voiceremote_inject_linux=info")
        .with_writer(std::io::stderr)
        .try_init();
    if matches!(cli.command, Command::Dictate { .. }) {
        println!("dictate toggle: stub; phone capture control is not connected");
        return Ok(());
    }
    let _lease = if !matches!(cli.command, Command::Devices | Command::Revoke { .. }) {
        Some(ReceiverLease::acquire(&cli.state_dir)?)
    } else {
        None
    };
    let keys = store(&cli)?;
    let registry = Registry::new(keys.clone());
    let (stop_send, stop) = watch::channel(false);
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        let _ = stop_send.send(true);
    });
    let injectors = injector_factory(
        &cli.state_dir,
        matches!(cli.command, Command::Run { headless: true, .. }),
    );
    match cli.command {
        Command::Devices => {
            for peer in registry.devices()? {
                println!(
                    "{}\t{:?}\t{:?}",
                    peer.id, peer.info.device_id, peer.info.display_name
                );
            }
        }
        Command::Revoke { device, relay } => {
            let peer = registry.resolve(&device)?;
            registry.revoke(&peer.id)?;
            if let Some(origin) = relay {
                let device = registry.local_id(None)?;
                relay_client(
                    &origin,
                    peer.info.account_id.clone(),
                    peer.room.clone(),
                    device,
                    keys.as_ref(),
                )?
                .revoke(&peer.info.device_id)
                .await
                .map_err(|_| {
                    anyhow::anyhow!("local enrollment revoked; relay revocation failed")
                })?;
            }
            println!("Revoked {:?} ({})", peer.info.display_name, peer.id);
        }
        Command::RelayKey { device, account } => {
            let device = pairing_id(&registry, device)?;
            registry.remember_local(&info(&account, &device))?;
            println!(
                "{}",
                RelayIdentity::load_or_create(keys.as_ref())?.public_key()
            );
        }
        Command::RelayBootstrap {
            device,
            account,
            room,
            relay,
        } => {
            let device = pairing_id(&registry, device)?;
            registry.remember_local(&info(&account, &device))?;
            let secret = std::env::var("VOICEREMOTE_RELAY_BOOTSTRAP_SECRET").map_err(|_| {
                anyhow::anyhow!(
                    "trusted provisioner must supply VOICEREMOTE_RELAY_BOOTSTRAP_SECRET"
                )
            })?;
            relay_client(&relay, account, room, device, keys.as_ref())?
                .bootstrap(&secret)
                .await?;
            println!("Controller room provisioned");
        }
        Command::Pair {
            qr,
            code: _,
            account,
            device,
            listen,
            relay,
            room,
            phone_device,
            phone_relay_key,
        } => {
            let device = pairing_id(&registry, device)?;
            let identity = Arc::new(Identity::load_or_create(keys.as_ref())?);
            let relay = if let Some(origin) = relay {
                Some(relay_client(
                    &origin,
                    account.clone(),
                    room.ok_or_else(|| {
                        anyhow::anyhow!("--room must name a provisioned controller room")
                    })?,
                    device.clone(),
                    keys.as_ref(),
                )?)
            } else {
                None
            };
            let mut offer = if let Some(client) = &relay {
                let phone = phone_device.as_deref().ok_or_else(|| {
                    anyhow::anyhow!("--phone-device required from trusted signing-key exchange")
                })?;
                let key = phone_relay_key.as_deref().ok_or_else(|| {
                    anyhow::anyhow!("--phone-relay-key required from trusted signing-key exchange")
                })?;
                let invitation = client.invite(phone, key, true).await?;
                Offer::from_relay_invite(
                    &identity,
                    account.clone(),
                    client.route.room.clone(),
                    invitation.one_use_token,
                    invitation.expires_at,
                    &SystemClock,
                )?
            } else {
                let room = format!(
                    "pair-{}",
                    base64::Engine::encode(
                        &base64::engine::general_purpose::URL_SAFE_NO_PAD,
                        Identity::generate()?.public
                    )
                );
                Offer::issue(&identity, account.clone(), room, &SystemClock)?
            };
            let listener = if relay.is_none() {
                let mut listener = match listen {
                    Some(address) => LanListener::bind(address).await?,
                    None => LanListener::bind_auto().await?,
                };
                listener.advertise(&offer.payload.relay_room_id)?;
                eprintln!(
                    "LAN pairing listener: {} (mDNS discovery)",
                    listener.address()?
                );
                Some(listener)
            } else {
                None
            };
            let mut connected = if let Some(client) = &relay {
                Some(Box::new(RelayTransport::connect(client).await?) as Box<dyn Transport>)
            } else {
                None
            };
            let complete:Result<_>=async {
            let payload = encode(&offer.payload).map_err(anyhow::Error::msg)?;
            if qr {
                println!(
                    "{}",
                    qrcode::QrCode::new(payload.as_bytes())?
                        .render::<qrcode::render::unicode::Dense1x2>()
                        .build()
                );
            } else {
                println!("{payload}");
            }
            let mut transport: Box<dyn Transport> = if let Some(transport) = connected.take() {
                transport
            } else {
                Box::new(
                    tokio::select! {result=tokio::time::timeout(Duration::from_secs(120),listener.as_ref().unwrap().accept())=>result??,_=receiver::stopped(stop.clone())=>bail!("pairing stopped")},
                )
            };
            let mut pending = tokio::select! {result=pairing::accept(transport.as_mut(),&identity,&mut offer,&SystemClock)=>result?,_=receiver::stopped(stop.clone())=>bail!("pairing stopped")};
            let phrase = pending.phrase();
            eprintln!("Compare on both devices: {phrase}\nType the entire phrase to confirm:");
            let entered = read_confirmation(stop.clone()).await?;
            pending
                .confirm_local(transport.as_mut(), &entered, info(&account, &device))
                .await?;
            tokio::select! {result=tokio::time::timeout(Duration::from_secs(120),pending.receive_confirmation(transport.as_mut()))=>result??,_=receiver::stopped(stop.clone())=>bail!("pairing stopped")};
            if let Some(expected) = phone_device.as_deref() {
                ensure!(
                    pending
                        .remote_info()
                        .is_some_and(|i| i.device_id == expected),
                    "Noise peer ID differs from relay invitation"
                );
            }
            let session = pending.finish(registry.clone())?;
            Ok((session,transport))
            }.await;
            let (session, mut transport) = match complete {
                Ok(pair) => pair,
                Err(error) => {
                    // A joined phone whose Noise confirmation failed must not
                    // strand membership and prevent the next fresh invitation.
                    if let (Some(client), Some(phone)) = (&relay, phone_device.as_deref()) {
                        let _ = client.revoke(phone).await;
                    }
                    if *stop.borrow() {
                        return Ok(());
                    }
                    return Err(error);
                }
            };
            let peer = session.peer().clone();
            println!("Paired {} ({})", peer.info.device_id, peer.id);
            if let Some(listener) = listener {
                receiver::run_lan(
                    listener,
                    identity,
                    registry,
                    peer,
                    device,
                    injectors,
                    stop,
                    Some((session, transport)),
                )
                .await?;
            } else {
                let _ = receiver::serve(
                    session,
                    transport.as_mut(),
                    injectors().as_mut(),
                    stop.clone(),
                )
                .await;
                receiver::run_relay(
                    relay.unwrap(),
                    identity,
                    registry,
                    peer,
                    device,
                    injectors,
                    stop,
                )
                .await?;
            }
        }
        Command::Run {
            headless: _,
            agents_config,
            account,
            device,
            listen,
            relay,
            peer,
        } => {
            let device = registry.local_id(device.as_deref())?;
            ensure!(
                registry.local_info()?.unwrap().account_id == account,
                "local account differs from pairing"
            );
            let identity = Arc::new(Identity::load_or_create(keys.as_ref())?);
            let peers: Vec<_> = registry
                .devices()?
                .into_iter()
                .filter(|p| p.info.account_id == account)
                .collect();
            let peer = match peer {
                Some(id) => {
                    let peer = registry.resolve(&id)?;
                    ensure!(peer.info.account_id == account, "cross-account peer");
                    peer
                }
                None if peers.len() == 1 => peers.into_iter().next().unwrap(),
                _ => bail!("select --peer from devices"),
            };
            let agents = agents_config
                .map(|path| -> Result<_> {
                    voiceremote_agents::AgentNode::new(
                        voiceremote_agents::Allowlist::load(&path)?,
                        voiceremote_agents::CliAdapter::default(),
                        keys.clone(),
                    )
                })
                .transpose()?;
            if let Some(node) = agents {
                if let Some(origin) = relay {
                    voiceremote_agents::receiver::run_relay(
                        node,
                        relay_client(
                            &origin,
                            account,
                            peer.room.clone(),
                            device.clone(),
                            keys.as_ref(),
                        )?,
                        identity,
                        registry,
                        peer,
                        device,
                        injectors,
                        stop,
                    )
                    .await?;
                } else {
                    let mut listener = match listen {
                        Some(address) => {
                            voiceremote_agents::transport::Listener::bind(address).await?
                        }
                        None => voiceremote_agents::transport::Listener::bind_auto().await?,
                    };
                    listener.advertise(&peer.room)?;
                    voiceremote_agents::receiver::run_lan(
                        node, listener, identity, registry, peer, device, injectors, stop,
                    )
                    .await?;
                }
                return Ok(());
            }
            if let Some(origin) = relay {
                receiver::run_relay(
                    relay_client(
                        &origin,
                        account,
                        peer.room.clone(),
                        device.clone(),
                        keys.as_ref(),
                    )?,
                    identity,
                    registry,
                    peer,
                    device,
                    injectors,
                    stop,
                )
                .await?;
            } else {
                let mut listener = match listen {
                    Some(address) => LanListener::bind(address).await?,
                    None => LanListener::bind_auto().await?,
                };
                listener.advertise(&peer.room)?;
                eprintln!("LAN receiver listener: {}", listener.address()?);
                receiver::run_lan(
                    listener, identity, registry, peer, device, injectors, stop, None,
                )
                .await?;
            }
        }
        Command::Dictate { .. } => unreachable!(),
    }
    Ok(())
}

#[cfg(test)]
mod agent_cli_tests {
    use super::*;
    #[test]
    fn agent_config_requires_explicit_headless_opt_in() {
        assert!(
            Cli::try_parse_from([
                "voiceremote",
                "run",
                "--account",
                "test-account",
                "--agents-config",
                "/synthetic/config.toml"
            ])
            .is_err()
        );
        assert!(
            Cli::try_parse_from([
                "voiceremote",
                "run",
                "--headless",
                "--account",
                "test-account",
                "--agents-config",
                "/synthetic/config.toml"
            ])
            .is_ok()
        );
    }
}

#[cfg(test)]
mod injector_tests {
    use super::*;
    #[test]
    fn headless_agent_never_needs_display_or_portal() {
        let factory = injector_factory(std::path::Path::new("/not-created-for-agent"), true);
        assert_eq!(
            factory()
                .insert_text("synthetic")
                .unwrap_err()
                .downcast_ref::<voiceremote_core::InsertionFailure>(),
            Some(&voiceremote_core::InsertionFailure::NotStarted)
        );
    }
}
