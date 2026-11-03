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
| [lib.rs](lib.rs) | Private command admission; role/capability checks and durable replay receipts | ✅ synthetic tests |
| [registry.rs](registry.rs) | Strict owner TOML, exact workspace/session identity, bounded owner metadata discovery | ✅ synthetic tests |
| [process.rs](process.rs) | `AgentAdapter`, cloud stub, subprocess exit/JSON checks, opt-in smoke | ✅ fake CLIs; live providers unverified |
| [receiver.rs](receiver.rs) | Concurrent LAN/relay controls and three execution slots | ✅ synthetic Noise cancellation/revocation tests |
| [transport.rs](transport.rs) | Bounded split TCP/WebSocket pumps; preserve pending Noise reads | ✅ synthetic LAN/relay tests; deployment unverified |

Start at `receiver::serve`; REQ-34/41/44/60.
See [boundaries](../README.md) before embedding.
