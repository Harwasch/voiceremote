```mermaid
flowchart LR
    CLI[voiceremote] --> Pair[QR/code + human phrase]
    CLI --> Registry[devices / revoke]
    CLI --> Run[run --headless: concurrent LAN / relay retry]
    CLI --> Toggle[../tray/src/control.rs: private local toggle request]
    CLI --> Relay[relay-key / privileged relay-bootstrap]
    Pair & Run --> Core[../core]
    Run --> Desktop[Windows/Linux injectors + shared encrypted focus polling]
    Run --> Agents[../agents: opt-in exact-session CLI dispatch + concurrent controls]
```

| Path | What it is | Status |
|---|---|---|
| [src/](src/) | CLI, fresh signed rooms/invites, Windows/Linux shared focus, headless receivers and opt-in agents | ✅ synthetic tests; native Windows and physical phone unverified |
| [tests/](tests/) | CLI code pairing, persisted custom identity/restart, unknown/name/ID revoke, SIGINT during stalled handshake | ✅ |
| [Cargo.toml](Cargo.toml) | Binary, keychain opt-in, synthetic e2e-test injector and loopback access; Windows console-free hotkey `tray` feature | ✅ no Tauri |

Start with `cargo run -p voiceremote-app -- --help` from `SW/desktop`.
See [desktop README](../../README.md) for storage, LAN exposure and relay setup.
REQ-16/18–25/27/41/44/57. Windows and Linux use one encrypted focus/session driver.
Desktop mode selects the platform injector; `run --headless` requires no display.
Linux paste waits up to 30 seconds, restores if still owned, and reports unconfirmed
without retrying. Real Windows/GNOME behavior and phone UI are **unverified**.
`dictate toggle` sends a bounded request over the current user’s socket/named pipe;
it fails when no single phone session or capture state is available. It reports
request delivery, not a microphone transition. Phone interpretation is **unverified**. Provider execution requires headless `--agents-config`
([adapters](../agents/README.md)).

`bash SYS/tests/e2e/run.sh` verifies actual Worker/Swift WebSocket and LAN
exchanges with the opt-in fixed synthetic TextInjector, including resume/revoke
and a real persisted stale queue.
