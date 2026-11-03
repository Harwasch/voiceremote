```mermaid
flowchart LR
    Tests[adapters.rs] --> Pair[Real Noise XX / resume]
    Pair --> Node[AgentNode]
    Node --> Fake[Temporary claude / codex + systemd controls on PATH]
    Fake --> Assert[argv / stdin / receipts / slots / setsid child]
```

| File | What | Status |
|---|---|---|
| [adapters.rs](adapters.rs) | Synthetic Linux integration coverage; no real providers or keys | ✅ |
| [../src/process.rs](../src/process.rs) | Exit/signal unit test and env-gated live smoke | ✅ fake test; live smoke deliberately skipped |

Start: `HEAVY_CPUS=4 heavy cargo test -p voiceremote-agents --manifest-path
SW/desktop/Cargo.toml -j4`. REQ-34/41/44. Python 3 runs temporary fake executables;
scope/control fakes use only their own synthetic PID records (no process-environment scans). Only synthetic text is written in temporary directories. No parent PATH/env mutation.

Regressions cover same-connection LAN/relay cancel, revoke during execution, three
workers plus a control connection, escaped child sessions, unknown cleanup without
a bus or after control failure, retry after restart/expiry, restricted Claude
profiles, role/capability denial, flag-leading IDs and recovered Codex errors.
Real systemd/cgroup enforcement and live providers remain **unverified**.

The failure-matrix fixture delays its fake launcher by 300 ms to reproduce loaded
CI startup. Non-timeout cases get a 5-second budget; the hung case still gets
200 ms. Exit 7 and timeout SIGKILL assertions remain exact. A separate process
regression proves an already observed exit 7 survives a later pipe deadline and
cleanup without a user bus. Real CI logs lacked that timing detail.
