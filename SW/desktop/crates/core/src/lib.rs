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
    /// OS adapters may override this to isolate blocking providers. The default
    /// preserves compatibility with existing Linux and synthetic injectors.
    fn insert_text_async<'a>(
        &'a mut self,
        text: &'a str,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send + 'a>> {
        Box::pin(async move { self.insert_text(text) })
    }
}

/// Only NotStarted certifies that no input was queued and permits retry.
/// Untyped adapter errors are conservatively treated as Unconfirmed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertionFailure {
    NotStarted,
    Unconfirmed,
}
impl std::fmt::Display for InsertionFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::NotStarted => "insertion not started; safe to retry",
            Self::Unconfirmed => "insertion unconfirmed; do not retry automatically",
        })
    }
}
impl std::error::Error for InsertionFailure {}
