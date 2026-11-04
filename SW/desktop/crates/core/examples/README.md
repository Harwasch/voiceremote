```mermaid
sequenceDiagram
  participant Swift as NoiseInteropTests
  participant Rust as phone_interop
  Rust-->>Swift: Synthetic QR
  Swift->>Rust: XX + confirmation + fragmented Unicode
  Rust-->>Swift: Phrase + confirmation + fragmented Unicode
  Swift->>Rust: Fresh session/v1 XX
  Rust-->>Swift: Authenticated ready
  Swift->>Rust: Metadata; revoke in phone-revoke case
  Rust-->>Swift: Metadata; revoke in desktop-revoke case
```

| File | Purpose / inputs | Status |
|---|---|---|
| [phone_interop.rs](phone_interop.rs) | Real desktop pairing/session boundary over hex-framed stdin/stdout; synthetic QR, test clock and Unicode payload; ephemeral private key store | ✅ Swift process-pair tests on Linux |

Start: [interop command](../../../../../SYS/protocol/noise.md#phone-session-and-process-interop).
REQ-22–25. The Swift test invokes `cargo run -j4` automatically. This is a test
harness; no network listener, trusted UI or real user content. Desktop production
behavior is unchanged. Rust and Swift each encrypt and independently verify the
other's packets; output contains only synthetic control records and ciphertext.
