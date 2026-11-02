```mermaid
flowchart LR
  Tests[Synthetic segments] --> Writer[QueueWriter]
  Writer --> Reader[QueueReader]
  Reader --> Fake[Recording / interrupted inserter]
  Child[Linux child: immediate process exit during drain] --> Restart[Fresh reader + persisted ledger]
```

| File | What | Status |
|---|---|---|
| [KeyboardBridgeTests.swift](KeyboardBridgeTests.swift) | Ordering, ID dedup, crash gaps/process termination, expiry, caps, corrupt files, controls/newline rejection | ✅ Linux |

Start with `testNoSendRejectsAllControlsAndNewlinesBeforeQueueAndAtDrain` ([REQ-16])
and `testProcessTerminationMidDrain`. See the [package](../README.md) for the command.
UIKit Send behavior in Messages/Mail remains **unverified** ([REQ-46]).
