```mermaid
flowchart LR
  Tests[Swift tests] --> Router & Cleanup & AB[AB export]
  AB --> Schema[SW/bench run.schema.json]
  Tests --> Bridge[Python test socket] --> Server[Loopback RFC6455 fake]
```

| File | What | Status |
|---|---|---|
| [RouterTests.swift](RouterTests.swift) | Consent/selection, stable text after failure, offline silence, cleanup composition | ✅ Synthetic |
| [CleanupTests.swift](CleanupTests.swift) | Meaning edits, Send, CRLF/control clusters, vocabulary, raw/error/timeout fallback | ✅ Synthetic |
| [ABRunnerTests.swift](ABRunnerTests.swift) | Identical PCM, 200-case aggregation, measured timing, scalar ID and offline schema validation | ✅ Synthetic |
| [CloudTests.swift](CloudTests.swift) | Both vendor protocols, valid chunks, warning/EOS retention; deterministic idle/cancellation checkpoints | ✅ Loopback |
| [ManualIdleClock.swift](ManualIdleClock.swift) | Test-driven virtual time and explicit sleep-registration checkpoints; no timer sleeps | ✅ Synthetic |
| [BenchSchemaValidator.swift](BenchSchemaValidator.swift) | Foundation/CoreFoundation validator for the STT schema keywords; invalid fixtures too | ✅ Offline |
| [FakeWebSocket.py](FakeWebSocket.py) | Stdlib masked WebSocket server/bridge; invented text/PCM only | ✅ Loopback |
| [SttTests.swift](SttTests.swift) | Existing sample-count boundary checks | ✅ Synthetic |

Start with [package test commands](../README.md). Benchmark schema tests use Foundation/CoreFoundation
only, reading the authoritative schema without external tools or installation. Python 3 is needed
only for the stdlib local WebSocket fixture; `uv` is not required, including on CI.
No vendor traffic or owner recordings. [REQ-9]–[REQ-12], [REQ-21].
Purpose: test map. Inputs: synthetic fixtures and authoritative bench schema. Verification:
Linux only; phone inference, native URLSession WebSockets and Apple builds remain **unverified**.

The active-stream regression uses the production activity wrapper with a virtual clock, then an
engine-level stale-deadline/final-text scenario. Idle expiry, connect timeout, send/receive resets,
failed I/O and cancellation use explicit checkpoints, without wall-clock scheduling assumptions.
The former 30 ms pacing / 100 ms idle test injected a fake socket; it never called Apple's
`URLSessionWebSocketTask`. Native Apple transport execution still awaits coordinator CI/device tests.

Task 6 capture interruption addition ([REQ-5], [REQ-50], [REQ-56]): `CaptureSource.events()`
carries frames or terminal `.interrupted`; finite legacy sources default to frame wrapping.
Live sources must implement interruption events. EngineRouter discards all uncommitted text
on loss (including offline), and A/B refuses to export an interrupted run. Consumers use
events rather than stripping the loss signal via `frames()`. Existing engine PCM interfaces
remain unchanged. [InterruptedCaptureTests](../Tests/InterruptedCaptureTests.swift) cover
loss/late-frame rejection and A/B failure; Apple/BLE behavior is **unverified**.
