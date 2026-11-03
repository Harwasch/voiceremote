//! REQ-16/18–21/57: literal insertion and content-free focus metadata.
//! Native APIs and the TextInjector implementation exist only on Windows.
pub mod policy;
pub mod worker;

#[cfg(windows)]
mod native;
#[cfg(windows)]
pub use native::{WindowsInjector, focus_snapshot};
