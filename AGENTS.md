# AI working rules for this repo

*(The one shared instruction file. Codex reads this; `CLAUDE.md` imports it with
`@AGENTS.md`. Edit here, not in both.)*

This repo, `voiceremote`, is a monorepo for the voice remote system (called Voice
Control Fabric in the product definition): the iPhone app and keyboard,
the Windows/Linux receiver and agent node, the cloud relay, the voice remote
(board + firmware), and the system documents behind them. Humans must be able to
navigate it easily. Keep the main tree clean.

## Where things go

| Content | Location |
|---|---|
| Human-reviewed, authoritative work (requirements, design, schematics, firmware, apps) | `SYS/`, `HW/`, `FW/`, `SW/` |
| External reference material (Apple/vendor docs, datasheets, standards, licences of reused code) | `DOCS/` |
| AI-generated analyses, research notes, scripts, benchmark runs, drafts | `AI/<DISCIPLINE>/` (mirrors `SYS`, `HW`, `FW`, `SW`) |
| Throwaway temp files | `AI/scratch/` (gitignored) |

- **`AI/` is the AI's workspace.** Scratch, scripts, benchmark runs, research
  notes, working analyses: everything AI produces to get to an answer.
- **The other root folders are for people.** They hold results: the design, the
  decisions, and the code people use. Write the result there and keep the
  working behind it in `AI/`, linked.
- Write a result straight into the main tree when a human asks for it there.
  Otherwise draft in `AI/` and promote once it is reviewed.
- Name AI outputs `AI/<DISCIPLINE>/YYYY-MM-DD-short-slug.md`. For multi-file
  work (script + results), use a folder with that same name.
- Put a short header at the top of every AI output: purpose, inputs used, and
  whether results are verified.
- Scripts that produced a result live next to that result so it can be
  reproduced.
- Don't add files to the repo root. Don't create new root folders without
  asking. (`.github/` is the one exception.)

## What is where, and what it releases

```mermaid
flowchart LR
  SYS[SYS: requirements, protocol + tool schemas] --> SW & FW & HW
  SW --> IOS[SW/ios: app + keyboard] & DESK[SW/desktop: Win/Linux receiver + agent node] & RELAY[SW/relay]
  FW --> REMOTE[voice remote] 
  HW --> REMOTE
  REMOTE -- BLE audio --> IOS
  IOS -- Noise, LAN or relay --> DESK
```

| Folder | Holds | Releases |
|---|---|---|
| `SYS/` | Product definition, system design, requirements (`[REQ-n]`, `[D-n]`, `[Q-n]`), protocol and tool schemas (source of truth for codegen), security and safety model, system test plans | — |
| `SW/ios/` | iPhone app, keyboard extension, Live Activity, Swift packages `Core`, `Stt`, `Brain` | `ios-v*` → TestFlight build |
| `SW/desktop/` | Rust workspace: `core`, `inject-windows`, `inject-linux`, `agents`, `app` (Tauri tray; `--headless` for agent nodes) | `desktop-v*` → Windows + Linux installers |
| `SW/relay/` | Cloudflare Worker + Durable Objects | `relay-v*` → Worker deploy |
| `SW/bench/` | STT + brain benchmark tools and curated phrase/command sets (audio in Git LFS) | — |
| `FW/` | Voice remote firmware (Proto 1 ESP32-C6; ESP32-S3 stand-in, ESP-IDF), host tools, `docs/characterisation/` | `fw-v*` → firmware images |
| `HW/` | Remote PCB + mic array (KiCad), enclosure and stand CAD, `fixtures/` | `hw-v*` → fab and assembly package |
| `DOCS/` | External references only | — |
| `AI/` | Working material. Not authoritative until promoted. | — |

A release tag must equal the component's declared version (Xcode marketing
version, `Cargo.toml`, `package.json`, firmware `VERSION`) or the release job
refuses it. **TBD:** the release scripts that enforce this.

## READMEs

Every folder that holds real content gets a `README.md`. A README is a map of
the folder, not an essay:

- **Lead with a diagram** (Mermaid) showing how this folder's pieces relate to
  each other and to the rest of the system.
- **Then a table** of what's in the folder: file or subfolder, what it is, status.
- **Show the thing.** Screenshots, renders, plots, board views.
- **Say where to start**, link the key files, name the `[REQ-n]` it satisfies.
- Status at a glance (✅ done · 🟡 in progress · ⬜ not started).
- No walls of prose. Past about one screen, move detail to a linked doc.
- Update the README in the same change that alters the folder's contents.

## Engineering rules

- **Prove it.** Every design decision and every claim that a requirement is met
  needs evidence: a measurement, a benchmark run, or an analysis. "Should work"
  is not evidence; unproven claims are marked **unverified**.
  - Speech and brain claims (WER, term accuracy, latency, battery) cite a
    `SW/bench/` run on a named device, with the run output in `AI/SW/`.
  - Commit the script that produced a result next to the result.
  - On-device measurements beat simulator or desktop numbers.
- **Requirements live in `SYS/`.** Design work traces back to `[REQ-n]`. Don't
  invent requirements; propose them in `AI/SYS/` or ask.
- **Contracts are mechanical, not prose.** The protocol and tool schemas in
  `SYS/` generate the Swift, Rust and TypeScript types. If you change a schema,
  regenerate and update its round-trip tests in the same commit.
- **Authority invariants (security).** Model output never sets
  `authenticated_actor`, `activation_kind`, `approval_credential_class` or
  `granted_scope_id`. Inferred (tier 1) actions never reach the execution queue
  without an approval event. Dictation never presses Send/Enter. Each of these
  is enforced by a test; changing the behaviour means changing the test in the
  same commit.
- **Privacy.** Never commit or log real transcripts, audio, contacts or keys.
  Benchmark audio is the owner's curated set only, in LFS, never in CI logs.
- Cite sources for every external number. Use `DOCS/` copies where they exist.
- Mark unverified numbers **TBC** and unknown numbers **TBD**. Never present a
  guess as fact.
- Code reused from Hex (anomalyco/hex) or Handy (MIT) keeps its licence header,
  and the licence goes in `DOCS/licences/`. No GPL code (e.g. VoiceInk).

## Hardware and firmware together

- **The board is the truth about the board.** `HW/` holds the real KiCad design;
  firmware pin claims are checked against it by a script, not by reading a PDF.
  **TBD** until P3 starts.
- The remote's physical OFF switch cuts microphone power in hardware. Firmware
  must not be able to override it. Test-board exception granted by the owner on
  2026-11-02: see [the BLE contract](SYS/protocol/remote-ble.md).

## Style

- Keep documents short and scannable: tables, not prose. No filler.
- **"Shall" statements belong in the requirements document only.**
- **Lead with the visual.** Put the plot or diagram where the reader hits the
  conclusion.

## Build and test

**TBD:** exact commands land with each component's first task. Planned:

| Component | Where it runs | Test command (planned) |
|---|---|---|
| `SYS/` schemas + codegen | hwgeekom | `make -C SYS check` |
| `SW/desktop` | hwgeekom (Linux); Windows via CI | `cargo test --workspace` |
| `SW/relay` | hwgeekom | `npm test` |
| `SW/ios` | **GitHub Actions macOS runner only** (no Mac) | `xcodebuild test` in CI |
| `FW/` | hwgeekom | `heavy bash FW/tests/run.sh` (host); board builds: see `FW/README.md`; ESP-IDF at `~/hw-tools/esp-idf` |

- **Compute tiers (owner's machines).** On hwgeekom, builds and tests up to
  10 cores / 20 GB go through `heavy <command>` (lowest priority, capped), one
  heavy job per project, parallelism 4 or less. Anything bigger goes to the cloud
  (`cloud-run`). hworker is for hardware only (lab and HIL), not compute.
- iOS cannot build on hwgeekom. Write Swift there, push, and read the CI result.
- **macOS CI minutes are scarce** (they count 10x on a private repo). The iOS
  workflow runs only on `ios-ci-*` tags, `ios-v*` tags and manual dispatch. Keep
  all logic that can be in plain Swift packages, testable with `swift test` on
  Linux, and put Apple-only code behind thin adapters.
- **Codex workers** run sandboxed in a worktree: they don't commit or push (the
  coordinator does), and `~/.cargo/bin` is on PATH via `export PATH=$HOME/.cargo/bin:$PATH`.

## Branches and PRs

Integration branch: `dev/integration`. `main` only moves when the owner accepts a
merge from it. One short-lived branch per task,
`<engine>/<type>-<slug>` (`claude/feat-pairing-qr`, `codex/fix-wayland-paste`),
types `feat fix clean hw sim research review docs`. Draft PR against `dev/integration`;
squash-merged after review. Never commit straight to `main`. Bug fixes start
with a failing test. Commit subjects are prefixed by area: `SYS:`, `SW:`, `FW:`,
`HW:`, `CI:`, `DOCS:`, `chore:`.

## Code Review Rules
<!-- read by review bots (Codex code review) -->
- Flag any change without a test for the behaviour it changes.
- Flag secrets, tokens, credentials, real transcripts or audio in code, config or logs.
- Flag a schema change in `SYS/` without regenerated types and updated round-trip tests.
- Flag any path where model output can set an authorization field, dispatch a
  tier 1 action without approval, or press Send/Enter during dictation.
- Flag a claim that a requirement or benchmark target is met without a bench run beside it.
- Flag new files at the repo root, new root folders nobody approved, and AI
  working material outside `AI/<DISCIPLINE>/`.
- Flag a folder whose contents changed without its `README.md` changing in the same PR.
- Flag GPL code, or reused MIT code without its licence header.
- Leave formatting and lint to CI.

## Lessons
<!-- one line per lesson learned after a merge; repo-specific only -->
