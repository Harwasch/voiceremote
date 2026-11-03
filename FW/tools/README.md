# Firmware host tools

```mermaid
flowchart LR
    Client[ble_client: Linux / BlueZ] <-->|BLE controls| Remote[StopWatch]
    Client --> Fixtures[synthetic phone labels]
```

| Folder | Purpose | Status |
|---|---|---|
| [ble_client/](ble_client/) | uv/Bleak scanner, explicit Numeric Comparison, Input monitor, fragmented Phone state writer | 🟡 Hardware unverified |

Start with its README. [REQ-8]/[REQ-18] bench support; no real personal data.
