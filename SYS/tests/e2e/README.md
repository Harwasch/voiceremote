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
  Phone->>Desktop: Prepare target; wait for display-ready
  Phone->>Desktop: Encrypted max Unicode dictation
  Desktop-->>Phone: Positive insertion outcome, then a real injector refusal
  Desktop->>Driver: Test TextInjector insertion event
  Driver->>Desktop: Stop process (relay case)
  Phone->>Relay: Adversarial captured stale ciphertext while desktop offline
  Driver->>Relay: Read-only SQLite assertion: frame persisted
  Driver->>Desktop: Restart with saved enrollment
  Relay->>Desktop: Replay stale queue; endpoint filters it
  Phone->>Desktop: Fresh resume + read-only outcome query + new dictation
  Phone->>Desktop: Revoke; next phone message rejected
  participant Proxy as Swift proxy-e2e
  participant Fake as Synthetic upstream
  Proxy->>Relay: Signed cloud challenges + proof headers
  Relay->>Fake: Both speech vendors + Claude Messages
  Fake-->>Proxy: Synthetic transcript / proposal response
```

| File | Purpose / inputs | Status |
|---|---|---|
| [agents.py](agents.py) | Production phone AppModel/STT/Brain, real Policy with fake biometric, Router, actual relay/Noise and agent node; fake Claude/Codex and systemd controls | ✅ Synthetic Linux path; live providers/Windows unverified |
| [run.sh](run.sh) | Sequential builds, four workers maximum, then local real-client exchange | ✅ Linux |
| [run.py](run.py) | Coordinate privately; verify ACK success/failure, durable query/same-ID dedup, relay process restart, max Unicode, Auto age/skew, LAN preference/closed-port relay fallback, stale queue and revoke | ✅ WS + LAN + preferred/fallback |
| [Package.resolved](Package.resolved) | Pinned Crypto/ASN.1 for production Swift clients | ✅ Linux resolved |
| [Package.swift](Package.swift), [ProxyClient/](ProxyClient/README.md) | Swift production Stt/Brain/Pairing clients; Linux loopback carrier | ✅ Exact query/body signing accepted |
| [relay.mjs](relay.mjs) | Bundle **production** `SW/relay/src/worker.ts`; start actual Miniflare SQLite DOs; optional synthetic cloud settings/provisioner/upstreams | ✅ no test fixture / no Worker source changes |

Run at repo root: `bash SYS/tests/e2e/run.sh`. Requires cargo, Swift 6.2, Node 22,
Python 3 and the relay's pinned npm dependencies (`npm ci` if absent).
Rust builds use the committed workspace lockfile with `--locked`.
REQ-22–25/61; plan task 2's two clients exchange messages **verified locally**.

The Rust executable is the real `voiceremote` CLI. Its opt-in `e2e-test` feature
adds an injector accepting only fixed synthetic text / maximum Unicode and a known pre-input failure, emitting content-free events;
normal builds select the platform adapter. HTTP/WS is
explicitly loopback-only in test mode; production still requires HTTPS/WSS.
The Swift executable uses the same PhoneConnection and LAN framing as ComputerLink, plus production pairing, Noise and relay auth over actual sockets. No mock relay, modified Worker entrypoint or pipe bypass is used. The separate cloud test substitutes only provider upstreams via Miniflare outboundService; the production relay performs membership, challenge, signature and policy checks.

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

Queue observations read private copies of the SQLite database and WAL, closing
each inspection connection without touching Workerd's live shared-memory state.

Cloud gate: a separate local production Worker uses explicit synthetic provisioning/provider markers and conservative test policy. The trusted Node provisioner creates/invites; Swift receives only the invitation and redeems with its own Ed25519 key. CloudEngine signs both speech queries (apostrophe, literal plus, Unicode, repeated terms); ClaudeBrain signs its exact final body with the configured model/version. Synthetic upstreams check vocabulary/credential injection and return invented responses. No SW/relay source changes, vendor requests or real keys/transcripts/audio.

The preferred-path case pairs over LAN with relay configured, then restarts the desktop with only relay. The phone proves closed-port LAN failure precedes fresh signed relay resume, queries and explicitly resends the same segment ID across paths without reinsertion. Each path queries a never-arrived ID, then sends that same ID exactly once. LAN-only resumes TCP without restarting the desktop; relay and preferred cases restart the process. Auto compares two synthetic focused devices by activity age despite extreme peer-clock skew and expires idle heartbeats. Display readiness uses the CLI auto-true presentation hook. mDNS discovery, impostor handling and capture control are outside this socket gate; portable unit tests cover candidate authentication/control policy. Native tray rendering and real mDNS remain **unverified**.


The agent path proves explicit capability refusal, fake-CLI session arguments, tier 1 review/tap, tier 3 biometric challenge, offline node hold/restart/release, status query, authority-field rejection and hybrid fast path. Its PASS line identifies real or fake containment; process trees are real. Runtime Job Objects require Windows acceptance.

Review path: fake CLIs reject unexpected session arguments, resource capability is explicitly enrolled, a tier-3 resource request returns dispatched/reply, and its linked successor stays held. Session continuation and resource opening remain unverified. The harness uses real systemd scopes when the user bus is available; otherwise its PASS line labels fake PID-based cleanup and unverified real cgroups.
