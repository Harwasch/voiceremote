```mermaid
flowchart LR
    main[main.rs] --> Core[voiceremote-core]
    main --> QR[terminal QR / full code]
    main --> Headless[core receiver supervisors]
    main --> Agents[agents: duplex headless controls + durable receipts]
    main --> Relay[signed relay API / explicit privileged bootstrap]
    main -->|Windows| Win[windows_receiver.rs: focus over Noise]
    Win --> Wire[windows_transport.rs: persistent framing / keepalive]
    main --> Inject[Windows TextInjector]
```

| File | What it is | Status |
|---|---|---|
| [main.rs](main.rs) | Pair, persisted device ID, name/ID revoke, signed relay provisioning, concurrent headless run and dictate stub | ✅ CLI tests; on-device unverified |
| [windows_receiver.rs](windows_receiver.rs) | Windows-only bounded receiver adapter; encrypted focus changes / 30-second heartbeat; synthetic Noise/fragmentation test on Linux | 🟡 native runtime unverified |
| [windows_transport.rs](windows_transport.rs) | Windows-only LAN/relay wire adapters retaining read progress and keepalive state across focus polls | ✅ synthetic partial-frame tests; native network unverified |

Start at `Cli` and `main`. Configuration/limitations are in
[desktop README](../../../README.md). REQ-16/18–21/22–25/27/57; no Tauri/overlay.
The Windows adapters mirror the core supervisors and wire checks because the
current core API has no metadata hook and its LAN receive cannot be cancelled.
Keep protocol/security behavior aligned if those core implementations change.
[desktop README](../../../README.md). REQ-22–25/27/41/44; agent execution is opt-in via owner allowlist. No Tauri or injection backend.
