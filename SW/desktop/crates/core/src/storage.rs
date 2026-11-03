//! Secrets and enrollment records. No key material is logged or Debug-derived.
use crate::{Result, ensure, protocol};
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use zeroize::Zeroizing;

pub trait KeyStore: Send + Sync {
    fn get(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>>;
    fn put(&self, name: &str, value: &[u8]) -> Result<()>;
    fn delete(&self, name: &str) -> Result<()>;
    /// Atomically reserve an idempotency marker, failing closed if unsupported.
    fn reserve(&self, _name: &str) -> Result<bool> {
        crate::bail!("atomic reservations unavailable")
    }
}

/// Explicit opt-in on Unix headless hosts. Directory 0700; files 0600.
/// On Windows use the os-keychain feature; Unix modes are not an ACL substitute.
pub struct FileKeyStore {
    root: PathBuf,
}
impl FileKeyStore {
    pub fn new(root: impl AsRef<Path>) -> Result<Self> {
        #[cfg(not(unix))]
        {
            let _ = root;
            crate::bail!("file key storage is supported only on Unix; enable os-keychain");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
            let root = root.as_ref().to_path_buf();
            if !root.exists() {
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(&root)?;
            }
            let meta = fs::symlink_metadata(&root)?;
            ensure!(
                meta.is_dir() && !meta.file_type().is_symlink(),
                "unsafe key directory"
            );
            ensure!(
                meta.permissions().mode() & 0o077 == 0,
                "key directory must be 0700"
            );
            Ok(Self { root })
        }
    }
    fn path(&self, name: &str) -> Result<PathBuf> {
        ensure!(
            !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'),
            "invalid storage name"
        );
        Ok(self.root.join(name))
    }
}
impl KeyStore for FileKeyStore {
    fn get(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let path = self.path(name)?;
        match fs::symlink_metadata(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
            Ok(meta) => {
                ensure!(
                    meta.is_file() && !meta.file_type().is_symlink(),
                    "unsafe key file"
                );
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    ensure!(
                        meta.permissions().mode() & 0o077 == 0,
                        "key file must be 0600"
                    );
                }
            }
        }
        Ok(Some(Zeroizing::new(fs::read(path)?)))
    }
    fn put(&self, name: &str, value: &[u8]) -> Result<()> {
        let path = self.path(name)?;
        let mut random = [0u8; 16];
        OsRng.fill_bytes(&mut random);
        let temporary = self.root.join(format!("tmp-{}", hex::encode(random)));
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let result = (|| -> Result<()> {
            let mut file = options.open(&temporary)?;
            file.write_all(value)?;
            file.sync_all()?;
            fs::rename(&temporary, &path)?;
            #[cfg(unix)]
            fs::File::open(&self.root)?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }
    fn reserve(&self, name: &str) -> Result<bool> {
        let path = self.path(name)?;
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(path) {
            Ok(mut file) => {
                file.write_all(b"reserved")?;
                file.sync_all()?;
                #[cfg(unix)]
                fs::File::open(&self.root)?.sync_all()?;
                Ok(true)
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
            Err(error) => Err(error.into()),
        }
    }
    fn delete(&self, name: &str) -> Result<()> {
        match fs::remove_file(self.path(name)?) {
            Ok(()) => {
                #[cfg(unix)]
                fs::File::open(&self.root)?.sync_all()?;
                Ok(())
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

#[cfg(feature = "os-keychain")]
pub struct OsKeyStore {
    pub service: String,
}
#[cfg(feature = "os-keychain")]
impl KeyStore for OsKeyStore {
    fn get(&self, name: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        match keyring::Entry::new(&self.service, name)?.get_secret() {
            Ok(secret) => Ok(Some(Zeroizing::new(secret))),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }
    fn put(&self, name: &str, value: &[u8]) -> Result<()> {
        Ok(keyring::Entry::new(&self.service, name)?.set_secret(value)?)
    }
    fn reserve(&self, name: &str) -> Result<bool> {
        // The CLI ReceiverLease excludes a second receiver process. This lock
        // additionally serializes all keychain registries inside this process.
        static GATE: Mutex<()> = Mutex::new(());
        let _guard = GATE
            .lock()
            .map_err(|_| crate::anyhow!("keychain poisoned"))?;
        if self.get(name)?.is_some() {
            return Ok(false);
        }
        self.put(name, b"reserved")?;
        Ok(true)
    }
    fn delete(&self, name: &str) -> Result<()> {
        match keyring::Entry::new(&self.service, name)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

pub struct Identity {
    private: Zeroizing<Vec<u8>>,
    pub public: Vec<u8>,
}
impl Identity {
    pub fn generate() -> Result<Self> {
        let key = snow::Builder::new(crate::pairing::PATTERN.parse()?).generate_keypair()?;
        Ok(Self {
            private: Zeroizing::new(key.private),
            public: key.public,
        })
    }
    pub fn load_or_create(store: &dyn KeyStore) -> Result<Self> {
        if let Some(private) = store.get("identity")? {
            return Self::from_private(private);
        }
        let identity = Self::generate()?;
        store.put("identity", &identity.private)?;
        Ok(identity)
    }
    fn from_private(private: Zeroizing<Vec<u8>>) -> Result<Self> {
        ensure!(private.len() == 32, "invalid local identity");
        let secret: [u8; 32] = private.as_slice().try_into()?;
        let secret = Zeroizing::new(secret);
        let public = x25519_dalek::x25519(*secret, x25519_dalek::X25519_BASEPOINT_BYTES).to_vec();
        Ok(Self { private, public })
    }
    pub fn private(&self) -> &[u8] {
        &self.private
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Peer {
    pub id: String,
    pub public_key: Vec<u8>,
    pub generation: String,
    pub room: String,
    pub info: protocol::DeviceInfo,
}

/// Clone this handle for all sessions. Peer existence is reloaded on each message,
/// including changes made by a separate `revoke` CLI process.
#[derive(Clone)]
pub struct Registry {
    store: Arc<dyn KeyStore>,
    gate: Arc<Mutex<()>>,
}
impl Registry {
    pub fn new(store: Arc<dyn KeyStore>) -> Self {
        Self {
            store,
            gate: Arc::new(Mutex::new(())),
        }
    }
    pub fn enroll(
        &self,
        public_key: Vec<u8>,
        room: String,
        info: protocol::DeviceInfo,
    ) -> Result<Peer> {
        let _guard = self
            .gate
            .lock()
            .map_err(|_| crate::anyhow!("registry poisoned"))?;
        ensure!(public_key.len() == 32, "invalid peer key");
        protocol::encode(&info).map_err(anyhow::Error::msg)?;
        let id = hex::encode(Sha256::digest(&public_key));
        let mut generation = [0; 32];
        OsRng.fill_bytes(&mut generation);
        let peer = Peer {
            id: id.clone(),
            public_key,
            generation: hex::encode(generation),
            room,
            info,
        };
        let mut ids: Vec<String> = match self.store.get("devices")? {
            Some(data) => serde_json::from_slice(&data)?,
            None => vec![],
        };
        if !ids.contains(&id) {
            ids.push(id.clone());
        }
        self.store.put("devices", &serde_json::to_vec(&ids)?)?;
        self.store
            .put(&format!("peer-{id}"), &serde_json::to_vec(&peer)?)?;
        Ok(peer)
    }
    pub fn devices(&self) -> Result<Vec<Peer>> {
        let ids: Vec<String> = match self.store.get("devices")? {
            Some(data) => serde_json::from_slice(&data)?,
            None => return Ok(vec![]),
        };
        ids.iter()
            .filter_map(|id| self.peer(id).transpose())
            .collect()
    }
    pub fn peer(&self, id: &str) -> Result<Option<Peer>> {
        self.store
            .get(&format!("peer-{id}"))?
            .map(|data| serde_json::from_slice(&data).map_err(Into::into))
            .transpose()
    }
    pub fn require(&self, peer: &Peer) -> Result<()> {
        let current = self
            .peer(&peer.id)?
            .ok_or_else(|| crate::anyhow!("device revoked"))?;
        ensure!(current.generation == peer.generation, "enrollment replaced");
        Ok(())
    }
    pub fn remember_local(&self, info: &protocol::DeviceInfo) -> Result<()> {
        protocol::encode(info).map_err(anyhow::Error::msg)?;
        if let Some(existing) = self.local_info()? {
            ensure!(
                existing.device_id == info.device_id && existing.account_id == info.account_id,
                "local device/account differs from existing enrollment"
            );
        }
        self.store.put("local-device", &serde_json::to_vec(info)?)
    }
    pub fn local_info(&self) -> Result<Option<protocol::DeviceInfo>> {
        self.store
            .get("local-device")?
            .map(|b| serde_json::from_slice(&b).map_err(Into::into))
            .transpose()
    }
    pub fn local_id(&self, override_id: Option<&str>) -> Result<String> {
        let local = self
            .local_info()?
            .ok_or_else(|| crate::anyhow!("pair this receiver first"))?;
        if let Some(value) = override_id {
            ensure!(
                value == local.device_id,
                "--device differs from persisted pairing identity"
            );
        }
        Ok(local.device_id)
    }
    pub fn resolve(&self, query: &str) -> Result<Peer> {
        let devices = self.devices()?;
        if let Some(peer) = devices.iter().find(|peer| peer.id == query) {
            return Ok(peer.clone());
        }
        let matches: Vec<_> = devices
            .into_iter()
            .filter(|p| p.info.device_id == query || p.info.display_name == query)
            .collect();
        ensure!(
            matches.len() == 1,
            if matches.is_empty() {
                "unknown device"
            } else {
                "ambiguous device name; use ID"
            }
        );
        Ok(matches.into_iter().next().unwrap())
    }
    pub fn revoke(&self, id: &str) -> Result<()> {
        self.store.delete(&format!("peer-{id}"))
    }
    /// Durable at-most-once reservation before any later command dispatch.
    /// Keys are never evicted. Failed/unknown dispatch needs explicit reconciliation.
    pub fn claim_command(&self, peer: &Peer, key: &str) -> Result<bool> {
        let _guard = self
            .gate
            .lock()
            .map_err(|_| crate::anyhow!("registry poisoned"))?;
        self.require(peer)?;
        let name = format!(
            "command-{}-{}",
            peer.id,
            hex::encode(Sha256::digest(key.as_bytes()))
        );
        self.store.reserve(&name)
    }
    pub fn claim_segment(&self, peer: &Peer, id: &str) -> Result<bool> {
        let _guard = self
            .gate
            .lock()
            .map_err(|_| crate::anyhow!("registry poisoned"))?;
        self.require(peer)?;
        let name = format!(
            "segment-{}-{}",
            peer.id,
            hex::encode(Sha256::digest(id.as_bytes()))
        );
        self.store.reserve(&name)
    }
    fn segment_key(peer: &Peer, id: &str) -> String {
        format!(
            "segment-{}-{}",
            peer.id,
            hex::encode(Sha256::digest(id.as_bytes()))
        )
    }
    /// Only call after an adapter certifies no input was queued. No text is stored.
    pub fn release_unstarted_segment(&self, peer: &Peer, id: &str) -> Result<()> {
        self.store.delete(&Self::segment_key(peer, id))
    }
    pub fn finish_segment(&self, peer: &Peer, id: &str, inserted: bool) -> Result<()> {
        self.store.put(
            &Self::segment_key(peer, id),
            if inserted {
                b"inserted"
            } else {
                b"unconfirmed"
            },
        )
    }
    /// Persist negative evidence without occupying the atomic insertion claim.
    /// A concurrent later claimant still wins reserve exactly once. Existing or
    /// corrupt/incomplete claims are always uncertain, never safe to resend.
    pub fn segment_disposition(&self, peer: &Peer, id: &str) -> Result<Option<bool>> {
        let _guard = self
            .gate
            .lock()
            .map_err(|_| crate::anyhow!("registry poisoned"))?;
        self.require(peer)?;
        let key = Self::segment_key(peer, id);
        if let Some(value) = self.store.get(&key)? {
            return Ok(Some(value.as_slice() == b"inserted"));
        }
        self.store
            .put(&format!("never-claimed-{key}"), b"never_claimed")?;
        // Recheck after persistence: another Registry could have claimed in the
        // meantime. The insertion key, not the negative marker, is authoritative.
        Ok(self
            .store
            .get(&key)?
            .map(|value| value.as_slice() == b"inserted"))
    }
    /// A reservation left by a crash is uncertain, never a success acknowledgement.
    pub fn segment_inserted(&self, peer: &Peer, id: &str) -> Result<bool> {
        Ok(self
            .store
            .get(&Self::segment_key(peer, id))?
            .is_some_and(|v| v.as_slice() == b"inserted"))
    }
}

/// Hold for the lifetime of a pairing/receiver process. CLI revoke/devices remain
/// available. Embedders using OsKeyStore must take the same lease before receiving.
pub struct ReceiverLease {
    _file: fs::File,
}
impl ReceiverLease {
    pub fn acquire(root: &Path) -> Result<Self> {
        if !root.exists() {
            let mut builder = fs::DirBuilder::new();
            builder.recursive(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder.create(root)?;
        }
        let meta = fs::symlink_metadata(root)?;
        ensure!(
            meta.is_dir() && !meta.file_type().is_symlink(),
            "unsafe receiver directory"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            ensure!(
                meta.permissions().mode() & 0o077 == 0,
                "receiver directory must be 0700"
            );
        }
        let path = root.join("receiver-lock");
        if let Ok(meta) = fs::symlink_metadata(&path) {
            ensure!(
                meta.is_file() && !meta.file_type().is_symlink(),
                "unsafe receiver lock"
            );
        }
        let mut options = fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options.open(path)?;
        fs2::FileExt::try_lock_exclusive(&file)
            .map_err(|_| crate::anyhow!("another receiver owns this state directory"))?;
        Ok(Self { _file: file })
    }
}
