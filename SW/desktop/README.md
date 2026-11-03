```mermaid
flowchart LR
    Phone -->|QR + XX + both confirmations| Core[core: pairing / registry / Noise]
    Phone <-->|mDNS + LAN TCP| Transport[Transport trait]
    Phone <-->|relay WSS| Transport
    Transport <--> Core
    Schema[SYS/protocol] --> Protocol[generated protocol crate] --> Core
    CLI[app: voiceremote] --> Core
    CLI --> Supervisor[bounded LAN / relay retry]
    CLI --> Auth[Ed25519 relay provisioning + challenges]
    Core --> Injector[TextInjector: Windows + Linux paste / Unicode]
    Windows[Windows UI Automation] -->|metadata only| CLI
    Linux[Linux AT-SPI] -->|metadata only| CLI
```

| Path | What it is | Status |
|---|---|---|
| [crates/protocol/](crates/protocol/) | Generated strict JSON wire types/codecs | ✅ |
| [Cargo.lock](Cargo.lock) | Binary workspace dependency lockfile; retained for the coordinator to commit | ✅ |
| [crates/core/](crates/core/) | Checked-DH XX, dual confirmation, signed relay auth, bounded receiver, fragments, storage and injection boundary | ✅ synthetic tests; deployed interoperability unverified |
| [crates/app/](crates/app/) | CLI `voiceremote`, headless receiver, QR renderer, Windows/Linux injection and shared focus wiring | ✅ synthetic tests; Windows runtime and tray pending |
| [crates/inject-linux/](crates/inject-linux/) | X11 XTest / persistent Wayland portal/EIS; bounded clipboard restore and conservative focus | 🟡 synthetic tests; Xvfb CI and GNOME runtime unverified |
| [crates/inject-windows/](crates/inject-windows/) | Windows clipboard/Unicode injection, UIA focus and owner checklist | 🟡 Linux policy tests; Windows runtime and Notepad/Chrome/Teams unverified |
| [../../SYS/protocol/noise.md](../../SYS/protocol/noise.md) | Exact suite, prologues, confirmations, words and transport profile | ✅ published synthetic vectors |
| [../../.github/workflows/desktop.yml](../../.github/workflows/desktop.yml) | Daily Ubuntu/Windows tests, `desktop-v*` / `desktop-ci-*` tags, manual dispatch | 🟡 remote CI unverified |

Start with `core/tests/security.rs` and the [Noise profile](../../SYS/protocol/noise.md).
Trace: REQ-16, REQ-22–25, REQ-27, REQ-34, REQ-60/61. Tests prove synthetic
protocol behavior, not owner on-device acceptance or external network performance.

```sh
RUST_TEST_THREADS=4 HEAVY_CPUS=4 heavy cargo test --workspace --manifest-path SW/desktop/Cargo.toml -j4
HEAVY_CPUS=4 heavy cargo check --target x86_64-pc-windows-msvc --manifest-path SW/desktop/Cargo.toml -j4
HEAVY_CPUS=4 heavy cargo check --workspace --features os-keychain --manifest-path SW/desktop/Cargo.toml -j4
make -C SYS check
```

CLI examples (from `SW/desktop`, replace the account; LAN interface selection is automatic):

```sh
cargo run -p voiceremote-app -- pair --qr --account ACCOUNT
# Explicit operator-only bootstrap; reads VOICEREMOTE_RELAY_BOOTSTRAP_SECRET.
cargo run -p voiceremote-app -- relay-bootstrap --account ACCOUNT --room ROOM --relay https://RELAY-ORIGIN
# Phone public signing key comes from a trusted prior exchange, never the relay.
cargo run -p voiceremote-app -- pair --code --account ACCOUNT --relay https://RELAY-ORIGIN --room ROOM --phone-device PHONE --phone-relay-key PHONE_ED25519_BASE64
cargo run -p voiceremote-app -- devices
cargo run -p voiceremote-app -- revoke DEVICE_NAME_OR_FINGERPRINT
cargo run -p voiceremote-app -- run --headless --account ACCOUNT --peer PEER_KEY_FINGERPRINT
cargo run -p voiceremote-app -- dictate toggle
```

`--code` prints the complete QR JSON for transfer through a trusted channel; no
short low-entropy code or lasting credential is invented. Type the complete
four-word phrase after comparing both displays. Phone confirmation is also
mandatory. QR/token output belongs only on the local terminal; do not record it.
Relay config: `VOICEREMOTE_RELAY_URL` is an HTTPS/WSS **origin** (no path,
credentials or query), plus `VOICEREMOTE_ACCOUNT`. Ordinary operation uses a stored
Ed25519 signing key and signed challenges, **no bearer**. `relay-key --account
ACCOUNT` prints only the public key for trusted provisioning. Provisioning-secret
access is confined to the explicit `relay-bootstrap` operator command. Phone
joins using the QR token/expiry and its invited key before starting Noise.
The relay contract lacks remote discovery of that phone key; this prior trusted
exchange is required. [Exact flow and limitations](../../SYS/protocol/noise.md).

| Operational boundary | Behavior / limit |
|---|---|
| LAN exposure | Prefer a private Wi-Fi/Ethernet interface; exclude known Docker/veth/bridge/tunnel names (override with `--listen PRIVATE_IP:PORT`), ephemeral or configured TCP port, `_voiceremote._tcp.local.` discovery. No wildcard/public listener, firewall change or router mapping. Pairing retains the LAN listener while enrolled; `run` also listens while selected enrollment exists. This is the task-authorized LAN exception to design's broad “no inbound ports”. |
| Revocation | Deletes peer enrollment, retains local private identity. Every message checks disk/keychain generation; active CLI closes idle connection/listener on 250 ms polls. A phone revoke message deletes this phone's enrollment and closes transport. Add `--relay ORIGIN` (or configure the relay env var) to also sign `/revoke` and remove relay membership/queued traffic. Unknown IDs fail; names/IDs resolve uniquely. Whole-room deletion is absent from relay API; next-message rejection is tested. |
| Storage | Linux default: `$XDG_STATE_HOME/voiceremote` or `$HOME/.local/state/voiceremote`. Override with `--state-dir` / `VOICEREMOTE_STATE_DIR`; never put it in the repository. File fallback rejects symlinks and broad permissions: directories 0700, files 0600; atomic replacement + fsync. No automatic insecure fallback from keychain. |
| OS keychain | Build `--features os-keychain`, select `--keychain`. `keyring` uses Linux kernel keyring (`linux-native`) / Windows Credential Manager (`windows-native`). Live OS keychain behavior is **unverified**; Linux kernel keys follow login/session lifetime, so use file fallback for durable headless service storage. Windows refuses file fallback; keychain feature required there. |
| Local identity | Pairing persists local device/account identity. `run` defaults to it; a conflicting `--device` fails before opening a listener. Use a separate state directory for a separate account/device. |
| Receiver lifetime | Four concurrent LAN connections; admission 10 seconds; per-connection failures and filtered peers are non-fatal. TCP keepalive 10 s / 5 s interval; WS ping 10 s / missing traffic/pong 30 s; authenticated application idle timeout 90 s. Shutdown/revocation cancels pending handshakes and offline retries. Relay waits indefinitely for a phone on a healthy socket and reconnects with 500 ms–30 s bounded backoff. |
| Concurrency | One receiver lease per state directory; reuse the same state directory for every instance using the same keychain service. Embedders take `ReceiverLease` too. File journal claims are atomic across handles; keychain claims serialize within the leased process. Revocation/devices remain available from a second process. |
| Idempotency | Durable, separate command and committed-segment namespaces. Reserve before dispatch/injection, never evict. Certified pre-input failure releases the segment claim for retry. Uncertain/partial delivery or a crash retains its claim for reconciliation; replay reports uncertainty, never false success. Failure TaskStatus uses segment_id as command_id; unavailable means retryable, error means uncertain. Journal disk growth is unbounded; quota/retention policy **TBD**. |
| Dictation | Large JSON is split into independently encrypted packets ≤11,000 bytes; strict ordered reassembly precedes validation/injection. Maximum legal Unicode dictation fits the worker’s 16,384-byte frame cap. Malformed/interleaved fragments fail closed. Only validated committed text addressed to this desktop reaches `TextInjector`. C0/C1 controls and line/paragraph separators rejected; partial/stale/duplicate segments do not insert. Windows uses private clipboard paste (unconfirmed and retained after a queued chord), pre-chord restoration, Unicode fallback, UIA password/read-only denial and UIPI checks. Linux desktop mode uses inject-linux; headless mode needs no injector on either OS. Linux paste waits up to 30 seconds and restores the previous clipboard if still owned; delivery is reported unconfirmed, with no automatic retry. No text logged. |
| Desktop focus | Shared Windows/Linux app session adapter sends encrypted focus boolean + last input time on change with a 30-second heartbeat (sampled each second); no field values or titles. Its transport keeps partial LAN frames and relay heartbeat timers across focus polls. The core transport/supervisor APIs remain unchanged; both platforms use one driver and metadata sampler; unknown focus reports false. Native behavior and phone UI remain **unverified**; see [manual checks](crates/inject-windows/manual-test.md). |
| Commands | Default receiver reserves commands without execution. Opt-in headless `--agents-config` attaches exact-session CLI adapters through paired Noise; see [agent nodes](#agent-nodes) for authority, lifetime and cancellation limits. Core `AgentAdapter` remains a marker extension trait. |
| Relay gaps | The 32,768-byte offline queue cannot buffer the entire largest Unicode dictation; online fragmentation is tested, offline delivery of that size is not guaranteed. No anonymous first-pair key discovery, whole-room deletion or end-to-end fragment delivery acknowledgement is defined. Failed Noise pairing best-effort revokes the invited phone membership so a fresh invitation can be issued. |
| Timing / deployment | Compute pairing under one minute tested over loopback TCP and fake relay. Human time, home/external network, physical iPhone, mDNS on actual LAN, live TLS and Windows runtime **unverified**. |
| UI | `dictate toggle` explicitly reports a stub. `tray` feature reserved; no Tauri dependency. |

## Agent nodes

```mermaid
flowchart LR
    Phone[Paired iPhone / authorized_command] --> Noise[Encrypted LAN or relay]
    Noise --> Node[run --headless --agents-config]
    Owner[Owner allowlist: project + exact session] --> Node
    Node --> Claude[claude -p --resume]
    Node --> Codex[codex exec resume / explicit sandbox]
    Claude & Codex --> Status[task_status]
```

| Path | What | Status |
|---|---|---|
| [crates/agents/](crates/agents/README.md) | REQ-34/41/44: exact-session adapters + private durable replay claims | ✅ synthetic Linux Noise/fake CLI tests; live providers unverified |
| [User unit](crates/agents/systemd/voiceremote-agent.service) | Optional systemd template | 🟡 not installed |

Pair the host with the phone first using the existing `pair` command. Authenticate
installed Claude Code and Codex CLIs as that same Unix user through their own
supported login flow. The adapter reads no auth files and forwards no API keys.
Keep the allowlist outside the repository, owner-controlled (no group/other write).
`host` must equal the paired receiver's device ID, and `phone_device` its paired
iOS device ID. Use exact provider IDs from the owner's known sessions:

```toml
account = "ACCOUNT"
host = "hwgeekom"
phone_device = "PHONE_DEVICE_ID"
actor = "OWNER_ACTOR_ID"
max_command_age_ms = 30000
# Owner-selected resource limits, not benchmark measurements.
timeout_ms = 120000
max_output_bytes = 1048576

[[projects]]
project = "arm-design"
workspace = "/absolute/owner/project"
provider = "claude" # claude | codex | cloud (not configured)
account = "ACCOUNT"
host = "hwgeekom"
capability_profile = "read-only" # safest default if omitted; workspace-write enables edits
sessions = ["EXACT_PROVIDER_SESSION_ID"]
# Optional owner-exported metadata file, outside all agent workspaces:
# discovery_file = "/absolute/owner/config/arm-sessions.toml"
```

Each discovery entry has `[[sessions]]`, `provider_session_id`, and an absolute
`workspace` equal to this project's allowed directory. Unknown projects/sessions,
missing session IDs and cross-workspace entries reject. There is no latest-session
selection, provider fallback or home-directory transcript crawl.

```sh
cargo run -p voiceremote-app -- run --headless --account ACCOUNT --peer PEER_FINGERPRINT --agents-config /absolute/owner/agents.toml
HEAVY_CPUS=4 heavy cargo test -p voiceremote-agents --manifest-path SW/desktop/Cargo.toml -j4
```

Delegation requires phone-authenticated sensitive approval. Lifetime is bounded
from `created_at` because the current wire schema lacks exact expiry/preview bytes.
Cancel/revoke is read concurrently on the same paired LAN or relay connection.
Three execution slots reserve LAN capacity for controls. Per-task systemd user
scopes confirm tree cleanup; without a bus or confirmed cleanup, status remains
`running/unavailable` (unconfirmed), never cancelled. Retries return durable running
or terminal receipts. Live cgroups/providers and exact phone expiry remain
**unverified**; Windows execution refuses before spawning. See the complete
[operational boundaries](crates/agents/README.md).

Optional user-service setup (instructions only; none performed): place the built
binary at `~/.local/bin/voiceremote`, copy the unit to
`~/.config/systemd/user/voiceremote-agent.service`, and create private
`~/.config/voiceremote/agents.toml` plus `agent.env` containing only
`VOICEREMOTE_ACCOUNT=...` and `VOICEREMOTE_PHONE=...` (peer fingerprint).
Review the unit's PATH for installed CLIs, then run `systemctl --user daemon-reload`
and `systemctl --user enable --now voiceremote-agent`. The service and task scopes
default to `MemoryMax=2G`, `CPUQuota=100%` (**TBC**). Logs contain no transcripts;
provider CLI storage follows the provider's own retention policy. Service deployment
and permission-setting behavior on the owner machine are **unverified**.
