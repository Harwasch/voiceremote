```mermaid
sequenceDiagram
  participant Driver as run.py
  participant Phone as Swift phone-e2e
  participant Relay as Actual Worker / Miniflare
  participant Desktop as Real voiceremote CLI
  Desktop->>Relay: Signed create + token-hash invite
  Driver->>Phone: Desktop QR (memory only)
  Phone->>Relay: Redeem with own Ed25519 identity
  Phone->>Desktop: Socket generation rendezvous + Noise XX
  Driver->>Phone: Confirm matching phrases on both clients
  Phone->>Desktop: Encrypted dictation
  Desktop->>Driver: Test TextInjector insertion event
  Driver->>Desktop: Stop process (relay case)
  Phone->>Relay: Old-session ciphertext while desktop offline
  Driver->>Relay: Read-only SQLite assertion: frame persisted
  Driver->>Desktop: Restart with saved enrollment
  Relay->>Desktop: Replay stale queue; endpoint filters it
  Phone->>Desktop: Fresh rendezvous / session resume + dictation
  Phone->>Desktop: Revoke; next phone message rejected
```

| File | Purpose / inputs | Status |
|---|---|---|
| [run.sh](run.sh) | Sequential builds, four workers maximum, then local real-client exchange | ✅ Linux |
| [run.py](run.py) | Coordinate QR/phrase privately; assert exactly two insertions, restart, persisted queue, revoke and permanent 403 | ✅ WS + LAN |
| [relay.mjs](relay.mjs) | Bundle **production** `SW/relay/src/worker.ts`; start actual Miniflare SQLite room, admission, wake and cloud-budget DOs | ✅ no test fixture / no Worker source changes |

Run at repo root: `bash SYS/tests/e2e/run.sh`. Requires cargo, Swift 6.2, Node 22,
Python 3 and the relay's pinned npm dependencies (installed if absent).
REQ-22–25/61; plan task 2's two clients exchange messages **verified locally**.

The Rust executable is the real `voiceremote` CLI. Its opt-in `e2e-test` feature
adds an injector which accepts only `Synthetic e2e 🦀` and emits a fixed event;
normal builds select the platform adapter (Windows injection; Linux unavailable). HTTP/WS is
explicitly loopback-only in test mode; production still requires HTTPS/WSS.
The Swift executable uses production pairing, Noise, session, relay auth and LAN
framing, over actual sockets. No mock endpoint, permissive bearer server,
forwarding fake, modified Worker entrypoint or pipe bypass is in either path.

Relay assertions include actual room creation/QR redemption, both confirmations,
insertion, process restart, an old-session frame verified in the real SQLite queue
and replayed across resume, queue drain, outgoing revoke, local next-message
failure, desktop exit and a signed 403 after self-revocation. LAN independently
proves pairing, insertion, fresh TCP resume and revoke. The stale queued frame
never inserts. A test failure never prints QR/token/key/phrase or content.

Private temporary endpoint state and relay storage are deleted; all children are
reaped, including on failure. Only generated synthetic material is used. This is
local interoperability evidence; physical iPhone, Apple Keychain/Network/native
WebSocket, WAN/TLS deployment and human phrase-comparison time are **unverified**.
