//! Bounded LAN concurrency, cancellable peer waits, idle limits and relay retry.
use crate::{
    Result, TextInjector, pairing,
    relay::RelayClient,
    session::{Delivery, Session},
    storage::{Identity, Peer, Registry},
    transport::{LanListener, RelayTransport, Transport},
};
use std::{future::Future, sync::Arc, time::Duration};
use tokio::{sync::watch, task::JoinSet};

pub const CONNECTION_CAP: usize = 4;
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(90);
const POLL: Duration = Duration::from_millis(250);
pub type InjectorFactory = Arc<dyn Fn() -> Box<dyn TextInjector> + Send + Sync>;
pub async fn stopped(mut stop: watch::Receiver<bool>) {
    if !*stop.borrow() {
        let _ = stop.wait_for(|value| *value).await;
    }
}
/// Keeps futures alive while polling; never restarts a partially consumed frame.
async fn guarded<T>(
    future: impl Future<Output = Result<T>>,
    registry: &Registry,
    peer: &Peer,
    stop: watch::Receiver<bool>,
) -> Result<T> {
    tokio::pin!(future);
    let mut poll = tokio::time::interval(POLL);
    loop {
        tokio::select! {
            result=&mut future=>return result,
            _=poll.tick()=>registry.require(peer)?,
            _=stopped(stop.clone())=>crate::bail!("receiver stopped"),
        }
    }
}
pub async fn serve(
    mut session: Session,
    transport: &mut dyn Transport,
    injector: &mut dyn TextInjector,
    stop: watch::Receiver<bool>,
) -> Result<()> {
    loop {
        let registry = session.registry().clone();
        let peer = session.peer().clone();
        let message = guarded(
            async { Ok(tokio::time::timeout(IDLE_TIMEOUT, session.receive(transport)).await??) },
            &registry,
            &peer,
            stop.clone(),
        )
        .await;
        let message = match message {
            Ok(message) => message,
            Err(error) => {
                let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
                return Err(error);
            }
        };
        if session.deliver(transport, message, injector).await? == Delivery::Revoked {
            return Ok(());
        }
    }
}
#[async_trait::async_trait]
pub trait LanAcceptor: Send + Sync {
    async fn accept(&self) -> Result<crate::transport::LanTransport>;
}
#[async_trait::async_trait]
impl LanAcceptor for LanListener {
    async fn accept(&self) -> Result<crate::transport::LanTransport> {
        LanListener::accept(self).await
    }
}

pub async fn run_lan(
    listener: impl LanAcceptor,
    identity: Arc<Identity>,
    registry: Registry,
    peer: Peer,
    local: String,
    injectors: InjectorFactory,
    stop: watch::Receiver<bool>,
    initial: Option<(Session, Box<dyn Transport>)>,
) -> Result<()> {
    let mut tasks = JoinSet::new();
    if let Some((session, mut transport)) = initial {
        let stop = stop.clone();
        let injectors = injectors.clone();
        tasks.spawn(async move {
            let _ = serve(session, transport.as_mut(), injectors().as_mut(), stop).await;
            let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
        });
    }
    let mut poll = tokio::time::interval(POLL);
    loop {
        tokio::select! {
            _=stopped(stop.clone())=>break,
            _=poll.tick()=>{if registry.require(&peer).is_err(){break;}},
            _=tasks.join_next(),if !tasks.is_empty()=>{},
            accepted=listener.accept()=>{
                // A filtered non-LAN socket and per-connection errors never end the listener.
                let Ok(mut transport)=accepted else {tokio::time::sleep(Duration::from_millis(25)).await;continue;};
                if tasks.len()>=CONNECTION_CAP {let _=transport.close().await;continue;}
                let identity=identity.clone();let registry=registry.clone();let peer=peer.clone();let local=local.clone();let stop=stop.clone();let injectors=injectors.clone();
                tasks.spawn(async move {
                    let handshake=async {Ok(tokio::time::timeout(pairing::HANDSHAKE_STEP_TIMEOUT,pairing::resume_accept(&mut transport,&identity,&registry,&peer,&local)).await??)};
                    if let Ok(session)=guarded(handshake,&registry,&peer,stop.clone()).await {let _=serve(session,&mut transport,injectors().as_mut(),stop).await;}
                    let _=tokio::time::timeout(Duration::from_secs(1),transport.close()).await;
                });
            }
        }
    }
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    Ok(())
}
pub fn retry_delay(attempt: u32) -> Duration {
    Duration::from_millis(500u64.saturating_mul(1u64 << attempt.min(6)))
        .min(Duration::from_secs(30))
}
pub async fn run_relay(
    client: RelayClient,
    identity: Arc<Identity>,
    registry: Registry,
    peer: Peer,
    local: String,
    injectors: InjectorFactory,
    stop: watch::Receiver<bool>,
) -> Result<()> {
    let mut attempt = 0;
    loop {
        if *stop.borrow() || registry.require(&peer).is_err() {
            return Ok(());
        }
        if let Ok(mut transport) = guarded(
            RelayTransport::connect(&client),
            &registry,
            &peer,
            stop.clone(),
        )
        .await
        {
            // No 30s deadline around an idle, healthy relay waiting for the phone.
            if let Ok(session) = guarded(
                pairing::resume_accept(&mut transport, &identity, &registry, &peer, &local),
                &registry,
                &peer,
                stop.clone(),
            )
            .await
            {
                attempt = 0;
                let _ = serve(session, &mut transport, injectors().as_mut(), stop.clone()).await;
            }
            let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
        }
        if *stop.borrow() || registry.require(&peer).is_err() {
            return Ok(());
        }
        let delay = retry_delay(attempt);
        attempt = attempt.saturating_add(1);
        // Backoff is cancellable and revocation remains responsive while offline.
        let _ = guarded(
            async {
                tokio::time::sleep(delay).await;
                Ok(())
            },
            &registry,
            &peer,
            stop.clone(),
        )
        .await;
    }
}
