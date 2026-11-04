//! Synthetic AT-SPI service for the CI-only X11 field; exposes no field contents.
#![cfg(target_os = "linux")]
#![allow(dead_code)]
use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU32, Ordering},
    },
};
use zbus::{Connection, zvariant::OwnedObjectPath};
#[derive(Clone)]
struct Accessible {
    root: bool,
    role: Arc<AtomicU32>,
    large: Arc<AtomicBool>,
    stalled: Arc<AtomicBool>,
}
#[zbus::interface(name = "org.a11y.atspi.Accessible")]
impl Accessible {
    async fn get_state(&self) -> Vec<u32> {
        if self.stalled.load(Ordering::SeqCst) {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
        vec![if self.root {
            1 << 1
        } else {
            (1 << 7) | (1 << 8) | (1 << 12) | (1 << 24)
        }]
    }
    fn get_role(&self) -> u32 {
        if self.root {
            14
        } else {
            self.role.load(Ordering::SeqCst)
        }
    }
    fn get_children(&self) -> Vec<(String, OwnedObjectPath)> {
        if !self.root {
            return vec![];
        }
        let child = (
            "org.a11y.atspi.Registry".into(),
            OwnedObjectPath::try_from("/org/a11y/atspi/accessible/field").unwrap(),
        );
        vec![
            child;
            if self.large.load(Ordering::SeqCst) {
                513
            } else {
                1
            }
        ]
    }
}
struct Address(String);
#[zbus::interface(name = "org.a11y.Bus")]
impl Address {
    fn get_address(&self) -> &str {
        &self.0
    }
}
pub struct Accessibility {
    pub role: Arc<AtomicU32>,
    pub large: Arc<AtomicBool>,
    pub stalled: Arc<AtomicBool>,
    _connection: Connection,
    _runtime: tokio::runtime::Runtime,
    child: Child,
    _config: tempfile::TempDir,
}
impl Accessibility {
    pub fn new() -> Self {
        let config = tempfile::tempdir().unwrap();
        let path = config.path().join("bus.conf");
        std::fs::write(&path, r#"<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen><auth>EXTERNAL</auth><apparmor mode="disabled"/><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>"#).unwrap();
        let mut child = Command::new("/usr/bin/dbus-daemon")
            .arg("--config-file")
            .arg(path)
            .args(["--nofork", "--print-address=1"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut address = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut address)
            .unwrap();
        let address = address.trim().to_owned();
        // The sole ignored test runs --test-threads=1. Set once before creating
        // any runtime/injector threads; this isolated test process then exits.
        unsafe {
            std::env::set_var("DBUS_SESSION_BUS_ADDRESS", &address);
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .unwrap();
        let role = Arc::new(AtomicU32::new(79));
        let large = Arc::new(AtomicBool::new(false));
        let stalled = Arc::new(AtomicBool::new(false));
        let root = Accessible {
            root: true,
            role: role.clone(),
            large: large.clone(),
            stalled: stalled.clone(),
        };
        let field = Accessible {
            root: false,
            ..root.clone()
        };
        let connection = runtime.block_on(async {
            let c = zbus::connection::Builder::address(address.as_str())
                .unwrap()
                .build()
                .await
                .unwrap();
            c.request_name("org.a11y.Bus").await.unwrap();
            c.request_name("org.a11y.atspi.Registry").await.unwrap();
            c.object_server()
                .at("/org/a11y/bus", Address(address.clone()))
                .await
                .unwrap();
            c.object_server()
                .at("/org/a11y/atspi/accessible/root", root)
                .await
                .unwrap();
            c.object_server()
                .at("/org/a11y/atspi/accessible/field", field)
                .await
                .unwrap();
            c
        });
        Self {
            role,
            large,
            stalled,
            _connection: connection,
            _runtime: runtime,
            child,
            _config: config,
        }
    }
}
impl Drop for Accessibility {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
