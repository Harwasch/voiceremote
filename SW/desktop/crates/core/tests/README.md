```mermaid
flowchart LR
    Security[security.rs] --> LAN[TCP loopback peer]
    Security --> Relay[In-process WS fake]
    Auth[relay_contract.rs] --> Signed[HTTP challenge + Ed25519 + WS cap]
    Vectors[vectors.rs] --> Fixture[SYS/protocol/vectors/noise]
```

| File | Evidence | Status |
|---|---|---|
| [security.rs](security.rs) | Both transports, mandatory confirmation, token expiry/reuse, tamper/replay, revoke, dictation controls, deduplication, storage, virtual interfaces, delayed phone, bounded concurrency and cancellation | ✅ synthetic peers |
| [relay_contract.rs](relay_contract.rs) | Bootstrap/invite/join, signed challenge/WS, replay, max dictation, reconnect and revoke | ✅ independent auth fake |
| [check-token-guards.py](check-token-guards.py) | Opt-in live-peer token-guard mutation proof; always restores source | ✅ baselines pass; removed guards fail at runtime |
| [vectors.rs](vectors.rs) | Deterministic XX/confirmation/application ciphertext fixture | ✅ Rust; independent implementation unverified |

Start: `HEAVY_CPUS=4 heavy cargo test -p voiceremote-core --manifest-path SW/desktop/Cargo.toml -j4`.
Run from repository root. Fixture regeneration is documented
[beside the fixture](../../../../../SYS/protocol/vectors/noise/README.md).
REQ-16/22–25/27/34. No real transcripts, audio or production secrets.
Human pairing time and live network/OS behavior remain **unverified**.

Run `python3 SW/desktop/crates/core/tests/check-token-guards.py` alone (no concurrent desktop build) to reproduce the token guard mutation checks. Re-run normal tests afterward.
