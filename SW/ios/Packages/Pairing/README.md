```mermaid
sequenceDiagram
  participant Phone
  participant Desktop
  Phone->>Phone: Validate QR via ProtocolCodec
  Phone->>Desktop: XX message 1: e, empty payload
  Desktop->>Phone: XX message 2: e, ee, s, es, empty payload
  Phone->>Phone: Pin remote static key to QR
  Phone->>Desktop: XX message 3: s, se, encrypted one-use token
  Note over Phone,Desktop: Compare four words; confirm on each screen
  Phone->>Desktop: Encrypted 01 || handshake hash || DeviceInfo JSON
  Desktop->>Phone: Encrypted 01 || handshake hash || DeviceInfo JSON
  Phone->>Phone: Expose PairedPeer only after both confirmations
```

| Path | What | Status |
|---|---|---|
| [Package.swift](Package.swift) / [Package.resolved](Package.resolved) | iOS 26 minimum; pinned swift-crypto 4.0.0 + generated Protocol | ✅ Linux tested |
| [Sources/](Sources/README.md) | Noise XX, QR checks, phrase, confirmation gate and transport boundary | ✅ Unit tested |
| [Tests/](Tests/README.md) | Published vectors, protocol framing and negative security tests | ✅ Linux tested |

Start with [PairingConnection](Sources/PairingConnection.swift).
Run `swift test -j 4 --package-path SW/ios/Packages/Pairing`.
Trace: REQ-22/23/24/25/60/61; [wire contract](../../../../SYS/protocol/wire-contract.md).

| Wire choice | Definition |
|---|---|
| Crypto | `Noise_XX_25519_ChaChaPoly_BLAKE2s`, [Noise revision 34](https://noiseprotocol.org/noise.html); X25519/AEAD from swift-crypto, unkeyed BLAKE2s + Noise HMAC/HKDF locally implemented. |
| Prologue | `voiceremote/pair/v1` + NUL, u32-BE UTF-8 account length/account, u32-BE room length/room, raw 32-byte desktop key, u64-BE expiry. No JSON canonicalization. |
| Phrase | First four handshake-hash bytes, each indexed into the desktop's 16-prefix × 16-suffix dictionary; four space-separated words. |
| Confirmation | One encrypted transport message: byte `01`, raw 32-byte handshake hash, ProtocolCodec DeviceInfo JSON; same account, distinct device IDs. |
| Ordering | One Noise message per frame, ordered reliable transport. Same session for LAN/relay. Adapter owns framing/reconnect; never reset a live nonce stream. |

`SYS/protocol/noise.md` was absent on this base. The application profile above was
matched to the desktop worker's `SW/desktop/crates/core/src/pairing.rs` in sibling
worktree `codex-feat-desktop-core`; recheck against its authoritative document when integrated.
Bundled Cacophony and desktop snow 0.10.0 vectors prove byte interoperability,
including confirmations and application ciphertext. Actual desktop/phone
network pairing, Apple Keychain storage and on-device behavior remain **unverified**.

Trusted UI adapters supply identity keys, account, clock and confirmation taps;
feed only `finish()` results into Core's registry. Desktop owns token consumption,
replay rejection and the issuer monotonic deadline. Phone checks QR expiry twice
and pins the responder before sending the token. All I/O must honor cancellation;
closing transport must unblock I/O. Handshake deadline defaults to 30 seconds.
Raw `NoiseXX.split` is a cryptographic primitive, not an enrollment API.
