//! AT-SPI metadata only: never request names, field values, or Text.GetText.
use crate::{Focus, Session};
use anyhow::Result;
use std::collections::{HashSet, VecDeque};
use zbus::{Connection, Proxy, zvariant::OwnedObjectPath};
type Object = (String, OwnedObjectPath);
const ACCESSIBLE: &str = "org.a11y.atspi.Accessible";

pub(crate) async fn report(session: Session) -> Focus {
    let active = if session == Session::X11 {
        crate::x11::active_window()
    } else {
        None
    };
    if session == Session::X11 && active.is_none() {
        return Focus::Unknown;
    }
    let pid = active.and_then(crate::x11::window_pid);
    let focus = limited_query(query(pid)).await;
    if focus == Focus::Editable && active.is_some_and(crate::x11::terminal_window) {
        Focus::Terminal
    } else {
        focus
    }
}
async fn limited_query(query: impl std::future::Future<Output = Result<Focus>>) -> Focus {
    tokio::time::timeout(std::time::Duration::from_millis(500), query)
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or(Focus::Unknown)
}
async fn query(expected_pid: Option<u32>) -> Result<Focus> {
    let session = Connection::session().await?;
    let bus = Proxy::new(&session, "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus").await?;
    let address: String = bus.call("GetAddress", &()).await?;
    let connection = zbus::connection::Builder::address(address.as_str())?
        .build()
        .await?;
    query_connection(&connection, expected_pid).await
}
async fn query_connection(connection: &Connection, expected_pid: Option<u32>) -> Result<Focus> {
    let root = (
        "org.a11y.atspi.Registry".to_owned(),
        OwnedObjectPath::try_from("/org/a11y/atspi/accessible/root")?,
    );
    let mut pending = VecDeque::from([(root, false)]);
    let mut seen = HashSet::new();
    let mut focused = None;
    while let Some(((destination, path), ancestor_active)) = pending.pop_front() {
        if !seen.insert((destination.clone(), path.clone())) {
            continue;
        }
        if seen.len() > 512 {
            return Ok(Focus::Unknown);
        }
        let proxy =
            match Proxy::new(&connection, destination.as_str(), path.as_str(), ACCESSIBLE).await {
                Ok(p) => p,
                Err(_) => return Ok(Focus::Unknown),
            };
        let states: Vec<u32> = match proxy.call("GetState", &()).await {
            Ok(s) => s,
            Err(_) => return Ok(Focus::Unknown),
        };
        if state(&states, 12) && !state(&states, 6) {
            let role: u32 = proxy.call("GetRole", &()).await?;
            let current = classify(role, &states);
            // A password role anywhere claiming focus is a reason to fail closed.
            if current == Focus::Password {
                return Ok(Focus::Password);
            }
            let active = ancestor_active || state(&states, 1);
            let matches_active_window = if active {
                true
            } else if let Some(pid) = expected_pid {
                let bus = Proxy::new(
                    &connection,
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                )
                .await?;
                bus.call::<_, _, u32>("GetConnectionUnixProcessID", &(destination.as_str(),))
                    .await
                    .ok()
                    == Some(pid)
            } else {
                active
            };
            if !matches_active_window {
                continue;
            }
            if focused.is_some() {
                return Ok(Focus::Unknown);
            }
            focused = Some(current);
        }
        {
            let children = match proxy.call::<_, _, Vec<Object>>("GetChildren", &()).await {
                Ok(children) => children,
                Err(_) => return Ok(Focus::Unknown),
            };
            if children.len() + pending.len() > 512 {
                return Ok(Focus::Unknown);
            }
            pending.extend(
                children
                    .into_iter()
                    .filter(|(dest, path)| {
                        !dest.is_empty() && path.as_str() != "/org/a11y/atspi/null"
                    })
                    .map(|child| (child, ancestor_active || state(&states, 1))),
            );
        }
    }
    Ok(focused.unwrap_or(Focus::Unknown))
}
fn state(states: &[u32], bit: usize) -> bool {
    states
        .get(bit / 32)
        .is_some_and(|s| s & (1 << (bit % 32)) != 0)
}
fn classify(role: u32, states: &[u32]) -> Focus {
    // AT-SPI constants: PASSWORD_TEXT=40; EDITABLE=7, ENABLED=8, SENSITIVE=24.
    if role == 0 {
        Focus::Unknown
    } else if role == 40 {
        Focus::Password
    } else if role == 60 {
        Focus::Terminal
    } else if state(states, 7) && state(states, 8) && state(states, 24) {
        // Only roles whose text semantics we implement: TEXT, ENTRY, DOCUMENT_TEXT.
        // State bits alone cannot make an invalid/unrecognized role safe.
        if matches!(role, 61 | 79 | 94) {
            Focus::Editable
        } else {
            Focus::Unknown
        }
    } else {
        Focus::NotEditable
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Clone)]
    struct FakeAccessible {
        root: bool,
        role: std::sync::Arc<std::sync::atomic::AtomicU32>,
        mode: std::sync::Arc<std::sync::atomic::AtomicU32>,
    }
    #[zbus::interface(name = "org.a11y.atspi.Accessible")]
    impl FakeAccessible {
        async fn get_state(&self) -> Vec<u32> {
            if self.mode.load(std::sync::atomic::Ordering::SeqCst) == 3 {
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
            vec![if self.root {
                2
            } else {
                (1 << 7) | (1 << 8) | (1 << 12) | (1 << 24)
            }]
        }
        fn get_role(&self) -> u32 {
            self.role.load(std::sync::atomic::Ordering::SeqCst)
        }
        fn get_children(&self) -> zbus::fdo::Result<Vec<Object>> {
            let mode = self.mode.load(std::sync::atomic::Ordering::SeqCst);
            if !self.root {
                return if mode == 2 {
                    Err(zbus::fdo::Error::Failed("incomplete subtree".into()))
                } else {
                    Ok(vec![])
                };
            }
            Ok(vec![
                (
                    "org.a11y.atspi.Registry".into(),
                    OwnedObjectPath::try_from("/org/a11y/atspi/accessible/field").unwrap()
                );
                if mode == 1 { 513 } else { 1 }
            ])
        }
    }
    #[test]
    fn regression_accessibility_incomplete_large_or_timed_out_is_not_safe_focus() {
        use std::sync::{
            Arc,
            atomic::{AtomicU32, Ordering},
        };
        let bus = crate::portal::dbus_tests::Bus::new();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let c = bus.connection().await;
            c.request_name("org.a11y.atspi.Registry").await.unwrap();
            let role = Arc::new(AtomicU32::new(79));
            let mode = Arc::new(AtomicU32::new(0));
            c.object_server()
                .at(
                    "/org/a11y/atspi/accessible/root",
                    FakeAccessible {
                        root: true,
                        role: role.clone(),
                        mode: mode.clone(),
                    },
                )
                .await
                .unwrap();
            c.object_server()
                .at(
                    "/org/a11y/atspi/accessible/field",
                    FakeAccessible {
                        root: false,
                        role: role.clone(),
                        mode: mode.clone(),
                    },
                )
                .await
                .unwrap();
            assert_eq!(
                limited_query(query_connection(&c, None)).await,
                Focus::Editable
            );
            role.store(40, Ordering::SeqCst);
            assert_eq!(
                limited_query(query_connection(&c, None)).await,
                Focus::Password
            );
            role.store(60, Ordering::SeqCst);
            assert_eq!(
                limited_query(query_connection(&c, None)).await,
                Focus::Terminal
            );
            role.store(79, Ordering::SeqCst);
            for value in [1, 2, 3] {
                mode.store(value, Ordering::SeqCst);
                assert_eq!(
                    limited_query(query_connection(&c, None)).await,
                    Focus::Unknown
                );
            }
        });
    }
    #[test]
    fn unknown_role_cannot_be_made_safe_by_editable_state_bits() {
        for role in [0, u32::MAX] {
            assert_eq!(
                classify(role, &[(1 << 7) | (1 << 8) | (1 << 24)]),
                Focus::Unknown
            );
        }
    }
    #[test]
    fn role_and_state_only_focus_policy() {
        assert_eq!(classify(40, &[]), Focus::Password);
        assert_eq!(
            classify(79, &[(1 << 7) | (1 << 8) | (1 << 24)]),
            Focus::Editable
        );
        assert_eq!(classify(79, &[1 << 12]), Focus::NotEditable);
        assert!(!state(&[], 12));
    }
}

pub(crate) async fn activity() -> u64 {
    // Never fabricate activity from polling. If no trusted idle source exists,
    // zero makes the phone's Auto treat this receiver as inactive.
    let activity = tokio::time::timeout(std::time::Duration::from_millis(300), async {
        let connection = Connection::session().await.ok()?;
        let idle = Proxy::new(
            &connection,
            "org.gnome.Mutter.IdleMonitor",
            "/org/gnome/Mutter/IdleMonitor/Core",
            "org.gnome.Mutter.IdleMonitor",
        )
        .await
        .ok()?;
        let elapsed: u64 = idle.call("GetIdletime", &()).await.ok()?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_millis() as u64;
        now.checked_sub(elapsed)
    })
    .await
    .ok()
    .flatten()
    .unwrap_or(0);
    activity
}
