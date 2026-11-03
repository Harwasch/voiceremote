//! Desktop enrollment, transport and literal-text boundary (REQ-16, REQ-22–25).
mod crypto;
pub mod pairing;
pub mod receiver;
pub mod relay;
pub mod session;
pub mod storage;
pub mod transport;

pub use anyhow::{Result, anyhow, bail, ensure};
pub use voiceremote_protocol as protocol;

/// Extension points for later routing/provider crates. No execution authority here.
pub trait Target: Send + Sync {}
pub trait AgentAdapter: Send + Sync {}

/// Implementations insert literal text, never interpret it as keys or commands.
/// The receiver invokes this only for validated committed text, without controls.
pub trait TextInjector: Send {
    fn insert_text(&mut self, text: &str) -> Result<()>;
}
