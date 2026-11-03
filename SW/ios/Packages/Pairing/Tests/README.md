```mermaid
flowchart LR
  SYS[Shared SYS pair + fragments] --> NoiseTests
  NoiseInteropTests --> Rust[Real cargo phone_interop process]
  NoiseSessionTests --> Fragments[Bounds / replay / resume / revoke]
  NoiseRelayTests --> Fake[Independent Ed25519 sidecar + WebSocket fake]
  NoiseLANTests --> TCP[Byte stream splits + framing + address policy]
  NoiseURLSessionTests --> HTTP[Loopback HTTP limits / redirects / cancellation]
  PairingTests --> Gate[QR + trusted confirmations]
```

| File / folder | Evidence | Status |
|---|---|---|
| [NoiseTests.swift](NoiseTests.swift) | Byte-exact Cacophony + SYS pair/fragment vectors; phrase, confirmations, BLAKE2s, replay/reflection/low-order DH | ✅ Linux; required SYS files, no skips |
| [NoiseEpochTests.swift](NoiseEpochTests.swift) | Fake replays full old handshake/application/retained-state queues on connect; fresh XX succeeds; real adapters retain a live Noise state across ordered carrier changes | ✅ Linux |
| [NoiseInteropTests.swift](NoiseInteropTests.swift) | Live Rust desktop core: pairing, phrase, max Unicode each direction, resume, revoke from each endpoint | ✅ Two independent process pairs |
| [NoiseSessionTests.swift](NoiseSessionTests.swift) | Fragment grammar/bounds/UTF-8 split, deadline/cancel, accounts, revocation generation, key persistence, invalid resume | ✅ Linux |
| [NoiseRelayTests.swift](NoiseRelayTests.swift) | Signed join/challenge/connect/revoke, clock skew, lost-response recovery, permanent refusals, exact body hash, hostile responses, dropped count, retry cap/cancel, frame routing, ping deadline | ✅ Linux independent fake |
| [NoiseLANTests.swift](NoiseLANTests.swift) | Split/coalesced TCP frames, max packet, EOF/invalid lengths, private IP policy | ✅ Linux |
| [NoiseURLSessionTests.swift](NoiseURLSessionTests.swift) | Real loopback HTTP, streaming/declared response caps, redirect refusal, timeout and cancellation | ✅ Linux; Python 3 helper in test |
| [PairingTests.swift](PairingTests.swift) | QR/clock/profile; trusted confirmation gate and cancellation | ✅ Linux |
| [Fixtures/](Fixtures/README.md) | Published synthetic Cacophony and desktop snow vectors | ✅ Bundled |

Start with `NoiseTests.swift`. [Commands](../README.md).
`--filter Noise` includes all session/transport/interop suites. Full suite also runs
`PairingTests`. Host process tests compile on Linux/macOS; iOS device execution,
Keychain/Network adapters and native WebSocket operation remain **unverified**.
All inputs are public test secrets or synthetic values generated in memory.

[Real local gate](../../../../../SYS/tests/e2e/README.md) runs the production Worker, Rust CLI and Swift client over sockets, including persisted queue replay.
