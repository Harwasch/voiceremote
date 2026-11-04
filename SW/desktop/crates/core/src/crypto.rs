//! snow's pure-Rust primitives with contributory X25519 checks for every DH.
use snow::{
    Error,
    params::{CipherChoice, DHChoice, HashChoice},
    resolvers::{CryptoResolver, DefaultResolver},
    types::{Cipher, Dh, Hash, Random},
};
use subtle::ConstantTimeEq;
struct CheckedDh(Box<dyn Dh>);
impl Dh for CheckedDh {
    fn name(&self) -> &'static str {
        self.0.name()
    }
    fn pub_len(&self) -> usize {
        self.0.pub_len()
    }
    fn priv_len(&self) -> usize {
        self.0.priv_len()
    }
    fn set(&mut self, key: &[u8]) {
        self.0.set(key);
    }
    fn generate(&mut self, rng: &mut dyn Random) -> Result<(), Error> {
        self.0.generate(rng)
    }
    fn pubkey(&self) -> &[u8] {
        self.0.pubkey()
    }
    fn privkey(&self) -> &[u8] {
        self.0.privkey()
    }
    fn dh(&self, key: &[u8], output: &mut [u8]) -> Result<(), Error> {
        self.0.dh(key, output)?;
        if bool::from(output[..32].ct_eq(&[0u8; 32])) {
            return Err(Error::Dh);
        }
        Ok(())
    }
}
struct CheckedResolver;
impl CryptoResolver for CheckedResolver {
    fn resolve_rng(&self) -> Option<Box<dyn Random>> {
        DefaultResolver.resolve_rng()
    }
    fn resolve_dh(&self, choice: &DHChoice) -> Option<Box<dyn Dh>> {
        DefaultResolver
            .resolve_dh(choice)
            .map(|dh| Box::new(CheckedDh(dh)) as Box<dyn Dh>)
    }
    fn resolve_hash(&self, choice: &HashChoice) -> Option<Box<dyn Hash>> {
        DefaultResolver.resolve_hash(choice)
    }
    fn resolve_cipher(&self, choice: &CipherChoice) -> Option<Box<dyn Cipher>> {
        DefaultResolver.resolve_cipher(choice)
    }
}
pub fn builder<'a>() -> crate::Result<snow::Builder<'a>> {
    Ok(snow::Builder::with_resolver(
        crate::pairing::PATTERN.parse()?,
        Box::new(CheckedResolver),
    ))
}
