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
  participant Proxy as Swift proxy-e2e
  participant Fake as Synthetic upstream
  Proxy->>Relay: Signed cloud challenges + proof headers
  Relay->>Fake: Both speech vendors + Claude Messages
  Fake-->>Proxy: Synthetic transcript / proposal response
```

| File | Purpose / inputs | Status |
|---|---|---|
| [run.sh](run.sh) | Sequential builds, four workers maximum, then local real-client exchange | ✅ Linux |
| [run.py](run.py) | Coordinate QR/phrase privately; assert exactly two insertions, restart, persisted queue, revoke and permanent 403 | ✅ WS + LAN |
| [Package.resolved](Package.resolved) | Pinned Crypto/ASN.1 for production Swift clients | ✅ Linux resolved |
| [Package.swift](Package.swift), [ProxyClient/](ProxyClient/README.md) | Swift production Stt/Brain/Pairing clients; Linux loopback carrier | ✅ Exact query/body signing accepted |
| [relay.mjs](relay.mjs) | Bundle **production** `SW/relay/src/worker.ts`; start actual Miniflare SQLite DOs; optional synthetic cloud settings/provisioner/upstreams | ✅ no test fixture / no Worker source changes |

Run at repo root: `bash SYS/tests/e2e/run.sh`. Requires cargo, Swift 6.2, Node 22,
Python 3 and the relay's pinned npm dependencies (`npm ci` if absent).
Rust builds use the committed workspace lockfile with `--locked`.
REQ-22–25/61; plan task 2's two clients exchange messages **verified locally**.

The Rust executable is the real `voiceremote` CLI. Its opt-in `e2e-test` feature
adds an injector which accepts only `Synthetic e2e 🦀` and emits a fixed event;
normal builds select the platform adapter (Windows injection; Linux unavailable). HTTP/WS is
explicitly loopback-only in test mode; production still requires HTTPS/WSS.
The Swift executable uses production pairing, Noise, session, relay auth and LAN
framing, over actual sockets. No mock relay, modified Worker entrypoint or pipe bypass is used. The separate cloud test substitutes only provider upstreams via Miniflare outboundService; the production relay performs membership, challenge, signature and policy checks.

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

Cloud gate: a separate local production Worker uses explicit synthetic provisioning/provider markers and conservative test policy. The trusted Node provisioner creates/invites; Swift receives only the invitation and redeems with its own Ed25519 key. CloudEngine signs both speech queries (apostrophe, literal plus, Unicode, repeated terms); ClaudeBrain signs its exact final body with the configured model/version. Synthetic upstreams check vocabulary/credential injection and return invented responses. No SW/relay source changes, vendor requests or real keys/transcripts/audio.
