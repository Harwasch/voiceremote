//! Authenticated application boundary. There is deliberately no command executor.
use crate::{
    Result, TextInjector, ensure,
    protocol::*,
    storage::{Peer, Registry},
    transport::Transport,
};
use std::collections::HashMap;

pub const MAX_INNER_BYTES: usize = 2 * 1024 * 1024;

pub struct Session {
    state: snow::TransportState,
    registry: Registry,
    peer: Peer,
    local_device: String,
    failed: bool,
    revisions: HashMap<String, u64>,
    presentation_required: bool,
    prepared: Option<String>,
}
#[derive(Debug, PartialEq)]
pub enum Delivery {
    Inserted,
    Ignored,
    Duplicate,
    CommandReserved,
    Revoked,
    Metadata,
    InsertionNotStarted,
    InsertionUnconfirmed,
}
impl Session {
    pub(crate) fn new(
        state: snow::TransportState,
        registry: Registry,
        peer: Peer,
        local_device: String,
    ) -> Self {
        Self {
            state,
            registry,
            peer,
            local_device,
            failed: false,
            revisions: HashMap::new(),
            presentation_required: false,
            prepared: None,
        }
    }
    pub fn require_presentation(&mut self) {
        self.presentation_required = true;
    }
    pub fn presentation_ready(&mut self, id: Option<String>) {
        self.prepared = id;
    }
    pub fn registry(&self) -> &Registry {
        &self.registry
    }
    pub fn peer(&self) -> &Peer {
        &self.peer
    }
    pub fn check_active(&self) -> Result<()> {
        ensure!(!self.failed, "session closed");
        self.registry.require(&self.peer)
    }
    pub async fn send(
        &mut self,
        transport: &mut dyn Transport,
        message: &InnerMessage,
    ) -> Result<()> {
        self.check_active()?;
        transport.retained_session();
        let plain = encode(message).map_err(anyhow::Error::msg)?;
        check_accounts(&serde_json::to_value(message)?, &self.peer.info.account_id)?;
        ensure!(
            plain.len() <= MAX_INNER_BYTES,
            "application message exceeds receiver bound"
        );
        let bytes = plain.as_bytes();
        if bytes.len() + 16 <= crate::relay::PACKET_BYTES {
            self.write_packet(transport, bytes).await?;
        } else {
            let chunk_size = crate::relay::PACKET_BYTES - 16 - 9;
            for (index, chunk) in bytes.chunks(chunk_size).enumerate() {
                let mut fragment = vec![3];
                fragment.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
                fragment.extend_from_slice(&((index * chunk_size) as u32).to_be_bytes());
                fragment.extend_from_slice(chunk);
                self.write_packet(transport, &fragment).await?;
            }
        }
        Ok(())
    }
    async fn write_packet(&mut self, transport: &mut dyn Transport, plain: &[u8]) -> Result<()> {
        self.check_active()?;
        let mut packet = vec![0; crate::relay::PACKET_BYTES];
        let result = async {
            let n = self.state.write_message(plain, &mut packet)?;
            transport.send(&packet[..n]).await
        }
        .await;
        if result.is_err() {
            self.failed = true;
        }
        result
    }
    pub async fn receive(&mut self, transport: &mut dyn Transport) -> Result<InnerMessage> {
        if let Err(error) = self.check_active() {
            let _ =
                tokio::time::timeout(std::time::Duration::from_secs(1), transport.close()).await;
            return Err(error);
        }
        transport.retained_session();
        self.failed = true;
        let mut assembled = zeroize::Zeroizing::new(Vec::new());
        let mut expected_total = None;
        loop {
            let packet = transport.recv().await?;
            self.registry.require(&self.peer)?;
            ensure!(
                packet.len() <= crate::relay::PACKET_BYTES,
                "oversized Noise packet"
            );
            let mut plain = zeroize::Zeroizing::new(vec![0; crate::relay::PACKET_BYTES]);
            let n = self.state.read_message(&packet, &mut plain)?;
            ensure!(n > 0, "empty application packet");
            if plain[0] == 3 {
                ensure!(n > 9, "empty/truncated fragment");
                let total = u32::from_be_bytes(plain[1..5].try_into()?) as usize;
                let offset = u32::from_be_bytes(plain[5..9].try_into()?) as usize;
                ensure!(
                    total > 0 && total <= MAX_INNER_BYTES && offset == assembled.len(),
                    "invalid fragment size/offset"
                );
                ensure!(
                    expected_total.is_none_or(|previous| previous == total),
                    "interleaved fragments"
                );
                expected_total = Some(total);
                ensure!(assembled.len() + n - 9 <= total, "fragment overflow");
                assembled.extend_from_slice(&plain[9..n]);
                if assembled.len() < total {
                    continue;
                }
            } else {
                ensure!(expected_total.is_none(), "interleaved application packet");
                assembled.extend_from_slice(&plain[..n]);
            }
            let message: InnerMessage =
                decode(std::str::from_utf8(&assembled)?).map_err(anyhow::Error::msg)?;
            check_accounts(&serde_json::to_value(&message)?, &self.peer.info.account_id)?;
            self.failed = false;
            return Ok(message);
        }
    }

    /// Only this path reaches injection. Partial revisions never insert text.
    pub async fn deliver(
        &mut self,
        transport: &mut dyn Transport,
        message: InnerMessage,
        injector: &mut dyn TextInjector,
    ) -> Result<Delivery> {
        self.check_active()?;
        // Revalidate even when a caller passes a constructed Rust value.
        encode(&message).map_err(anyhow::Error::msg)?;
        check_accounts(&serde_json::to_value(&message)?, &self.peer.info.account_id)?;
        match message {
            InnerMessage::DictationText(text) => {
                ensure!(
                    text.target_device_id == self.local_device,
                    "wrong dictation target"
                );
                if self.presentation_required
                    && (self.prepared.is_none() || text.preparation_id != self.prepared)
                {
                    self.report_insertion(
                        transport,
                        &text.segment_id,
                        Some(crate::InsertionFailure::NotStarted),
                    )
                    .await?;
                    return Ok(Delivery::InsertionNotStarted);
                }
                if let Some(previous) = self.revisions.get(&text.segment_id) {
                    if text.revision <= *previous {
                        if text.state == DictationTextState::Committed {
                            self.report_insertion(
                                transport,
                                &text.segment_id,
                                if self
                                    .registry
                                    .segment_inserted(&self.peer, &text.segment_id)?
                                {
                                    None
                                } else {
                                    Some(crate::InsertionFailure::Unconfirmed)
                                },
                            )
                            .await?;
                        }
                        return Ok(Delivery::Duplicate);
                    }
                }
                ensure!(
                    self.revisions.len() < 4096 || self.revisions.contains_key(&text.segment_id),
                    "segment limit reached; reconnect"
                );
                if text.state == DictationTextState::Partial {
                    self.revisions
                        .insert(text.segment_id.clone(), text.revision);
                    return Ok(Delivery::Ignored);
                }
                if !self.registry.claim_segment(&self.peer, &text.segment_id)? {
                    self.report_insertion(
                        transport,
                        &text.segment_id,
                        if self
                            .registry
                            .segment_inserted(&self.peer, &text.segment_id)?
                        {
                            None
                        } else {
                            Some(crate::InsertionFailure::Unconfirmed)
                        },
                    )
                    .await?;
                    return Ok(Delivery::Duplicate);
                }
                self.check_active()?;
                let failure = injector
                    .insert_text_async(&text.text)
                    .await
                    .err()
                    .map(|error| {
                        error
                            .downcast_ref::<crate::InsertionFailure>()
                            .copied()
                            .unwrap_or(crate::InsertionFailure::Unconfirmed)
                    });
                if failure == Some(crate::InsertionFailure::NotStarted) {
                    self.registry
                        .release_unstarted_segment(&self.peer, &text.segment_id)?;
                } else {
                    self.revisions
                        .insert(text.segment_id.clone(), text.revision);
                    self.registry.finish_segment(
                        &self.peer,
                        &text.segment_id,
                        failure.is_none(),
                    )?;
                }
                self.report_insertion(transport, &text.segment_id, failure)
                    .await?;
                Ok(match failure {
                    None => Delivery::Inserted,
                    Some(crate::InsertionFailure::NotStarted) => Delivery::InsertionNotStarted,
                    Some(crate::InsertionFailure::Unconfirmed) => Delivery::InsertionUnconfirmed,
                })
            }
            InnerMessage::DictationQuery(query) => {
                ensure!(
                    query.target_device_id == self.local_device,
                    "wrong query target"
                );
                let inserted = self
                    .registry
                    .segment_inserted(&self.peer, &query.segment_id)?;
                self.report_insertion(
                    transport,
                    &query.segment_id,
                    if inserted {
                        None
                    } else {
                        Some(crate::InsertionFailure::Unconfirmed)
                    },
                )
                .await?;
                Ok(Delivery::Metadata)
            }
            InnerMessage::Revoke(revoke) => {
                ensure!(
                    revoke.device_id == self.local_device,
                    "revoke must address this receiver"
                );
                // Deleting the enrollment blocks every session, including the next packet.
                self.registry.revoke(&self.peer.id)?;
                self.failed = true;
                let _ = tokio::time::timeout(std::time::Duration::from_secs(1), transport.close())
                    .await;
                Ok(Delivery::Revoked)
            }
            InnerMessage::AuthorizedCommand(command) => {
                ensure!(
                    command.destination_id == self.local_device,
                    "wrong command target"
                );
                if !self
                    .registry
                    .claim_command(&self.peer, &command.idempotency_key)?
                {
                    return Ok(Delivery::Duplicate);
                }
                // No adapter is invoked. P1 must verify exact retained preview,
                // policy scope and trusted approval event before adding execution.
                Ok(Delivery::CommandReserved)
            }
            _ => Ok(Delivery::Metadata),
        }
    }
    async fn report_insertion(
        &mut self,
        transport: &mut dyn Transport,
        segment: &str,
        failure: Option<crate::InsertionFailure>,
    ) -> Result<()> {
        // A durable positive outcome follows successful native insertion. A lost
        // reply can be queried after resume without sending text again.
        self.send(
            transport,
            &InnerMessage::DictationOutcome(DictationOutcome {
                kind: DictationOutcomeKind::DictationOutcome,
                account_id: self.peer.info.account_id.clone(),
                segment_id: segment.into(),
                target_device_id: self.local_device.clone(),
                outcome: match failure {
                    None => DictationOutcomeOutcome::Inserted,
                    Some(crate::InsertionFailure::NotStarted) => {
                        DictationOutcomeOutcome::Unavailable
                    }
                    Some(crate::InsertionFailure::Unconfirmed) => {
                        DictationOutcomeOutcome::Unconfirmed
                    }
                },
            }),
        )
        .await
    }
}
fn check_accounts(value: &serde_json::Value, account: &str) -> Result<()> {
    match value {
        serde_json::Value::Object(fields) => {
            if let Some(value) = fields.get("account_id") {
                ensure!(value.as_str() == Some(account), "cross-account message");
            }
            for value in fields.values() {
                check_accounts(value, account)?;
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                check_accounts(value, account)?;
            }
        }
        _ => {}
    }
    Ok(())
}
