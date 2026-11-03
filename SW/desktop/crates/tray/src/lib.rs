//! GUI-independent tray model and adapters. No WebKit/GTK in the default build.
pub mod backend;
pub mod control;
#[path = "../../app/src/desktop_receiver.rs"]
pub mod desktop_receiver;
#[path = "../../app/src/desktop_transport.rs"]
pub mod desktop_transport;
pub mod model;

pub fn info(account: &str, device: &str) -> voiceremote_core::protocol::DeviceInfo {
    use voiceremote_core::protocol::*;
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
