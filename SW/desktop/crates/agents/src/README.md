```mermaid
flowchart LR
    transport[transport.rs: duplex packet pumps] --> receiver[receiver.rs: concurrent Noise controls]
    receiver --> node[lib.rs: validate + durable receipts]
    node --> registry[registry.rs: exact identity]
    node --> process[process.rs: bounded CLI + tree guard]
    process --> status[task_status]
```

| File | What | Status |
|---|---|---|
| [windows_job.rs](windows_job.rs) | Suspended start, kill-on-close Job Object, zero-active-process cleanup confirmation | 🟡 Windows cross-compile; runtime unverified |
| [lib.rs](lib.rs) | Private command admission; role/capability checks and durable replay receipts | ✅ synthetic tests |
| [registry.rs](registry.rs) | Strict owner TOML, exact workspace/session identity, bounded owner metadata discovery | ✅ synthetic tests |
| [process.rs](process.rs) | `AgentAdapter`, opt-in cloud handoff, subprocess exit/JSON checks, cleanup exit-status retention regression, opt-in smoke | ✅ fake CLIs; live providers unverified |
| [cloud.rs](cloud.rs) | Project cloud config, strict Session ID parsing, permission-override labels, uncertain launch receipts and repository checks | ✅ fake CLIs; live cloud unverified |
| [receiver.rs](receiver.rs) | Concurrent LAN/relay controls and three execution slots | ✅ synthetic Noise cancellation/revocation tests |
| [transport.rs](transport.rs) | Bounded split TCP/WebSocket pumps; shared core VRR1 epochs; preserve pending Noise reads | ✅ synthetic LAN/relay tests; deployment unverified |

Start at `receiver::serve`; REQ-34/41/44/60.
See [boundaries](../README.md) before embedding.


Inventory, retained-preview dispatch and durable status queries enter only through the paired receiver. HTTPS resource actions hand off to the selected CLI. See [supported entry points](../README.md#supported-command-entry-points-checked-2026-11-02).
