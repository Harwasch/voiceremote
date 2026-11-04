//! Full-duplex authenticated controls and bounded execution; never cancel a pending Noise read.
use crate::{
    AgentNode,
    transport::{Listener, PacketTransport},
};
use anyhow::Result;
use std::{sync::Arc, time::Duration};
use tokio::{sync::watch, task::JoinSet};
use voiceremote_core::{
    TextInjector, pairing,
    protocol::*,
    receiver::{self, InjectorFactory},
    relay::RelayClient,
    session::{Delivery, Session},
    storage::{Identity, Peer, Registry},
    transport::Transport,
};
pub async fn stopped(mut stop: watch::Receiver<bool>) {
    if !*stop.borrow() {
        let _ = stop.wait_for(|s| *s).await;
    }
}
async fn guarded<T>(
    future: impl std::future::Future<Output = Result<T>>,
    registry: &Registry,
    peer: &Peer,
    stop: watch::Receiver<bool>,
) -> Result<T> {
    tokio::pin!(future);
    let mut poll = tokio::time::interval(Duration::from_millis(100));
    loop {
        tokio::select! {
            result=&mut future => return result,
            _=poll.tick() => registry.require(peer)?,
            _=stopped(stop.clone()) => anyhow::bail!("agent receiver stopped"),
        }
    }
}
pub async fn serve(
    node: &AgentNode,
    mut session: Session,
    transport: &mut PacketTransport,
    injector: &mut dyn TextInjector,
    stop: watch::Receiver<bool>,
) -> Result<()> {
    let registry = session.registry().clone();
    let peer = session.peer().clone();
    let mut jobs = JoinSet::new();
    let mut owned = std::collections::HashSet::<String>::new();
    let mut poll = tokio::time::interval(Duration::from_millis(100));
    let idle = tokio::time::sleep(receiver::IDLE_TIMEOUT);
    tokio::pin!(idle);
    let result = loop {
        tokio::select! {
            _=stopped(stop.clone())=>break Ok(()),
            _=poll.tick()=>if registry.require(&peer).is_err(){break Err(anyhow::anyhow!("peer revoked"));},
            _=&mut idle,if jobs.is_empty()=>break Err(anyhow::anyhow!("idle session")),
            ready=transport.readable()=>{
                if let Err(error)=ready {break Err(error);}
                // Framing is drained by the packet pump, independent of task
                // execution. Bound fragmented messages; never cancel this read
                // merely because an execution finishes or a status is ready.
                let message=match guarded(async {Ok(tokio::time::timeout(Duration::from_secs(10),session.receive(transport)).await??)},&registry,&peer,stop.clone()).await {
                    Ok(message)=>message,Err(error)=>break Err(error),
                };
                idle.as_mut().reset(tokio::time::Instant::now()+receiver::IDLE_TIMEOUT);
                match message {
                    InnerMessage::AgentInventoryRequest(request)=>{
                        let reply = node.inventory(&session, &request)?;
                        session.send(transport, &InnerMessage::AgentInventory(reply)).await?;
                    },
                    InnerMessage::AgentTaskQuery(request)=>{
                        if let Ok(status) = node.query(&session, &request) {
                            session.send(transport, &InnerMessage::TaskStatus(status)).await?;
                        }
                    },
                    InnerMessage::AgentDispatch(dispatch)=>{
                        let admission=node.accept_dispatch(&session,dispatch);
                        let status=admission.result.status;
                        if let Some(work)=admission.work {
                            let worker=node.clone();let id=status.command_id.clone();owned.insert(id.clone());
                            jobs.spawn(async move {(id,worker.run(work).await)});
                        }
                        if let Err(error)=session.send(transport,&InnerMessage::TaskStatus(status)).await {break Err(error);}
                    },
                    InnerMessage::AuthorizedCommand(command)=>{
                        let admission=node.accept(&session,command);
                        let status=admission.result.status;
                        if let Some(work)=admission.work {
                            let worker=node.clone();let id=status.command_id.clone();owned.insert(id.clone());
                            jobs.spawn(async move {(id,worker.run(work).await)});
                        }
                        if let Err(error)=session.send(transport,&InnerMessage::TaskStatus(status)).await {break Err(error);}
                    },
                    message=>{
                        if matches!(message,InnerMessage::Revoke(_)){node.cancel_peer(&peer.id);}
                        match session.deliver(transport,message,injector).await {
                            Ok(Delivery::Revoked)=>break Ok(()),Ok(_)=>{},Err(error)=>break Err(error),
                        }
                    }
                }
            },
            completed=jobs.join_next(),if !jobs.is_empty()=>{
                match completed {
                    Some(Ok((id,result)))=>{
                        owned.remove(&id);
                        if let Err(error)=session.send(transport,&InnerMessage::TaskStatus(result.status)).await {break Err(error);}
                    },
                    _=>break Err(anyhow::anyhow!("execution worker stopped")),
                }
                idle.as_mut().reset(tokio::time::Instant::now()+receiver::IDLE_TIMEOUT);
            }
        }
    };
    for id in owned {
        node.cancel_id(&id);
    }
    if tokio::time::timeout(Duration::from_secs(10), async {
        while jobs.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        jobs.abort_all();
    }
    result
}
pub async fn run_lan(
    node: AgentNode,
    listener: Listener,
    identity: Arc<Identity>,
    registry: Registry,
    peer: Peer,
    local: String,
    injectors: InjectorFactory,
    stop: watch::Receiver<bool>,
) -> Result<()> {
    let mut tasks = JoinSet::new();
    let mut poll = tokio::time::interval(Duration::from_millis(100));
    loop {
        tokio::select! {
            _=stopped(stop.clone()) => break,
            _=poll.tick() => if registry.require(&peer).is_err() { break; },
            _=tasks.join_next(), if !tasks.is_empty() => {},
            accepted=listener.accept() => {
                let Ok(mut transport) = accepted else { continue; };
                if tasks.len() >= receiver::CONNECTION_CAP { let _ = transport.close().await; continue; }
                let node=node.clone(); let identity=identity.clone(); let registry=registry.clone(); let peer=peer.clone(); let local=local.clone(); let injectors=injectors.clone(); let stop=stop.clone();
                tasks.spawn(async move {
                    if let Ok(session) = guarded(async { Ok(tokio::time::timeout(pairing::HANDSHAKE_STEP_TIMEOUT, pairing::resume_accept(&mut transport, &identity, &registry, &peer, &local)).await??) }, &registry, &peer, stop.clone()).await {
                        let _ = serve(&node, session, &mut transport, injectors().as_mut(), stop).await;
                    }
                    let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
                });
            }
        }
    }
    if tokio::time::timeout(Duration::from_secs(12), async {
        while tasks.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        tasks.abort_all();
    }
    Ok(())
}
pub async fn run_relay(
    node: AgentNode,
    client: RelayClient,
    identity: Arc<Identity>,
    registry: Registry,
    peer: Peer,
    local: String,
    injectors: InjectorFactory,
    stop: watch::Receiver<bool>,
) -> Result<()> {
    let mut attempt = 0;
    while !*stop.borrow() && registry.require(&peer).is_ok() {
        if let Ok(mut transport) = guarded(
            PacketTransport::connect_relay(&client),
            &registry,
            &peer,
            stop.clone(),
        )
        .await
        {
            if let Ok(session) = guarded(
                pairing::resume_accept(&mut transport, &identity, &registry, &peer, &local),
                &registry,
                &peer,
                stop.clone(),
            )
            .await
            {
                attempt = 0;
                let _ = serve(
                    &node,
                    session,
                    &mut transport,
                    injectors().as_mut(),
                    stop.clone(),
                )
                .await;
            }
            let _ = tokio::time::timeout(Duration::from_secs(1), transport.close()).await;
        }
        let delay = receiver::retry_delay(attempt);
        attempt += 1;
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
    Ok(())
}
