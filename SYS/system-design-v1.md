*Exported 2026-11-02 from the living design doc: https://claude.ai/artifact/651nezV4iFEWVa28gKaKFe . That doc holds the two diagrams.*

# Voice Control Fabric — System Design & Plan v1

·

The iPhone runs the control plane's rules and tools, and a cloud LLM is the brain that decides what to do. Speech-to-text runs on the iPhone and must beat Apple dictation, with cloud as backup. Linux is both an agent node and a desktop text receiver. This doc builds on the Product Definition v0.2 and keeps all of its safety rules.

## Decisions locked

| Topic | Decision (2026-11-02) | Consequence |
| --- | --- | --- |
| Control plane | iPhone first, cloud relay second | Low latency; works off home network; no inbound ports on any PC |
| Speech-to-text | On-device iPhone, must beat Apple dictation; cloud fallback | Benchmark gate in P0 picks the engine |
| Linux | Agent node (hwgeekom, hworker) + desktop text receiver | Shared Rust receiver core for Windows and Linux |
| hwgeekom | Integrated GPU only | No heavy STT or LLM hosting there; it orchestrates agents |
| Scope | Full system design + phased plan | P0 is built first; P1 to P4 are designed now, built later |
| Builder | Codex CLI on hwgeekom | Plan is cut into Codex-sized tasks with acceptance tests |

Added 2026-11-02 (round 2):

| Topic | Decision | Consequence |
| --- | --- | --- |
| Mode toggle | New Dictation / AI Control switch next to the capture switch | Dictation skips the LLM entirely; see Modes |
| LLM brain | Cloud LLM with tools; phone keeps policy gate, registry, tool execution | On-device Apple model only for simple, fast commands |
| STT | Build every engine behind a switch and test them side by side | Engine picker in settings plus an A/B benchmark mode |
| iOS builds | GitHub Actions macOS runner (no Mac) | Codex writes Swift on hwgeekom; CI builds, signs, ships to TestFlight |

## System at a glance

Every microphone feeds the iPhone. The phone turns speech into text or tasks and sends them straight to a target on the LAN, or through the relay when you are away.

## Modes: Dictation vs AI Control

Two separate controls sit side by side on the phone and the remote. One says when to listen. The other says what happens to the words.

| Capture switch / Mode | Dictation | AI Control |
| --- | --- | --- |
| OFF | Mic off | Mic off |
| HOLD (PTT) | Words go to history and the active text field | Words go to the LLM brain as one command |
| CONTINUOUS | Live transcript to history and the active text field | Ambient suggestions (tier 1); wake phrase runs commands (tier 2) |

- Dictation: STT, then vocabulary and cleanup, then the history database and the focused field on the selected device. No LLM and no tools, so it is fast and predictable.
- AI Control: STT, then the LLM brain, then the policy gate, then tools. This is the full tier 1 to 3 model.
- The mode shows on the phone, the remote's screen, and the desktop tray icon. Switching mode never changes the target device.
- Remote hardware: a second 2-position switch, or a long-press on PTT (decided in P3).

Dictation target picker (phone and remote): choose one device, or Auto.

| Setting | Where the words go |
| --- | --- |
| A named device (iPhone, Windows laptop, Linux desktop, ...) | Always that device, until you change it |
| Auto | The device with the most recent keyboard, mouse, or touch activity in a text field (within 60 s); otherwise the iPhone |

- Each desktop receiver reports "active with a focused text field" to the phone. It sends no field contents, only that a field is focused.
- In Auto, the chosen device is shown before the first word lands: on the phone, the remote's screen, and a tray flash on the PC.
- On the remote, a short press of a side button cycles through the devices, with Auto as one stop. A spoken "dictate to laptop" works only in AI Control mode.

## Speech-to-text

Beating Apple takes three layers, not just one engine: a stronger acoustic model, biasing toward your own words, and a fast cleanup pass. The engine sits behind one `SttEngine` interface, so on-device and cloud engines can be swapped per utterance.

Layer 1: acoustic engine (candidates). Published numbers come from Macs, not iPhones. P0 re-measures every candidate on your phone with your voice.

| Engine | Where | Published WER | Custom vocabulary | Notes |
| --- | --- | --- | --- | --- |
| Apple SpeechAnalyzer (iOS 26) | On-device | 2.1% clean / 4.6% other ([Gigazine](https://www.gigazine.net/gsc_news/en/20260714-apple-speech-analyzer-benchmark/)); 14.0% Earnings22 ([Argmax](https://www.argmaxinc.com/blog)) | No | The baseline to beat; free; about the same as system dictation |
| NVIDIA Parakeet v2 via Argmax Pro SDK | On-device (Neural Engine) | 11.7% Earnings22, 359x real time ([Argmax](https://www.argmaxinc.com/blog)) | Yes (Pro SDK, Nov 2025) | Lead on-device pick; 160 ms streaming latency claimed; paid license |
| Whisper small.en via WhisperKit | On-device | 12.8% Earnings22 ([Argmax](https://www.argmaxinc.com/blog)) | Prompt only | MIT license; slower; open fallback |
| ElevenLabs Scribe v2 Realtime | Cloud | 2.2% AA-WER ([FutureAGI](https://futureagi.com/blog/best-voice-ai-july-2026/)) | Not stated | Cloud lead pick; under 150 ms claimed; about $0.39/hr |
| AssemblyAI Universal-3.5 Pro Realtime | Cloud | 3.1% AA-WER ([FutureAGI](https://futureagi.com/blog/best-voice-ai-july-2026/)) | Keyterm prompting | Cloud alternative; about $0.45/hr |

Layer 2: your vocabulary. Names, project terms (hwgeekom, hworker, Codex), and contacts feed a per-user word list. The list biases the engine where supported and the cleanup pass everywhere.

Layer 3: cleanup pass. A small model fixes punctuation, casing, numbers, and filler words before text is committed. It runs on-device when it fits, with a cloud LLM as backup. It never changes meaning and never adds a Send.

Engine choice per utterance:

- Default: on-device engine.
- Switch to cloud when there is no on-device model, the phone is hot or low on battery, or the user sets a "max accuracy" mode.
- Offline: on-device only, with no error shown to the user.

P0 benchmark gate. You record about 200 phrases on AirPods and the iPhone mic: normal voice, whispering, names, numbers, and tech terms. Each engine is scored on WER, term accuracy, clipped first words, time to first text, and battery per 10 minutes. The engine ships only if it beats Apple on your set. The proposed target is at least 25% fewer errors on your terms; you can change it.

Built to test many engines: every engine ships in debug builds behind a settings picker. An A/B mode runs two engines on the same audio and saves both results, so you can compare them on real use, not just the benchmark.

## Control plane: phone vs cloud

The LLM brain runs in the cloud, but its hands run on the phone. The LLM only proposes tool calls. The phone's deterministic policy gate approves or blocks them and then runs them. Dictation mode never touches the LLM, so it works offline on the home LAN.

Can the LLM run on the iPhone? Only partly. Apple's on-device Foundation Models (about 3B parameters, iOS 26, with tool calling) can handle short commands like "send this to the laptop". It is not reliable enough for multi-step agent work like "ask the arm-design session to compare, then summarize". So the plan is:

| Command type | Brain | Why |
| --- | --- | --- |
| Simple routing (switch target, start/stop, open X) | On-device Apple model | Fast, offline, free |
| Multi-step, agent tasks, ambient suggestions | Cloud LLM (Claude API) with tools | Much stronger reasoning and tool use |
| Policy, approvals, Face ID, tool execution | Phone code, never an LLM | Authority must be deterministic |

Brain picker: the brain sits behind an `LlmBrain` interface, like the STT engines, so you can set any brain and test fully on-device. Settings offer On-device only, Hybrid (the default above), and Cloud only.

| On-device brain candidate | Runtime | Notes |
| --- | --- | --- |
| Apple Foundation Models (about 3B) | Apple framework, iOS 26 | Built in, tool calling, no download |
| Open models of 3B to 4B (for example Qwen or Gemma class) | MLX Swift or llama.cpp | A 2 to 3 GB download; tool calling quality varies |

The benchmark kit gets a command set as well (about 50 spoken commands with expected tool calls). Every brain is scored on correct tool call, latency, and battery, the same way as the STT engines.

| Job | iPhone | Cloud relay |
| --- | --- | --- |
| Speech-to-text | Default | Fallback engine (via proxy, keys stay off the phone) |
| Intent + cleanup | Simple commands and cleanup | LLM brain for agent and multi-step commands |
| Policy gate, approvals, Face ID | Always | Never |
| Device registry | Source of truth | Encrypted backup |
| Message delivery | LAN direct | Relay when off-LAN |
| Task queue for offline targets | Holds while awake | Holds when the phone sleeps |

Two paths after speech:

- Dictation: committed text goes straight to the chosen target (Windows or Linux field, or the iOS keyboard). There is no policy step, because inserting text is pre-approved and Send is never pressed.
- Command: text goes through intent, then the policy gate, then the router, then an agent. Status comes back to the phone.

Latency targets (design goals, measured in P0):

| Stage | Target |
| --- | --- |
| Speech start to first partial text on phone | 300 ms or less |
| End of speech to committed text | 500 ms or less |
| Cleanup pass | 150 ms or less |
| Delivery to PC | 30 ms on LAN, 150 ms via relay |
| End of speech to text in PC field | 800 ms or less on LAN |

## Components

There are five builds: one iPhone app with a keyboard, one desktop and agent binary for Windows and Linux, one cloud relay, and later the remote's firmware. Every PC runs the same desktop binary in a different role.

| Component | Tech | Main jobs |
| --- | --- | --- |
| iPhone app (control plane) | Swift, SwiftUI, AVAudioEngine, Core ML, App Intents, Live Activity | Capture, STT, intent, policy gate, router, device registry, approval UI, Face ID |
| iOS keyboard extension | Swift; App Group plus Darwin notifications to the app | Inserts committed text via `UITextDocumentProxy`; no mic, no network (fits keyboard memory limits) |
| Cloud relay | Cloudflare Workers + Durable Objects (WebSocket) | End-to-end encrypted message relay, presence, APNs wake, offline task queue, cloud STT proxy, LLM brain calls |
| Desktop receiver (Windows) | Rust core + Tauri tray UI | Pairing, typing into the focused field (SendInput, UI Automation for focus), local agent adapters |
| Desktop receiver (Linux) | Same Rust core | X11 via XTest; Wayland via the RemoteDesktop portal (libei), uinput as fallback |
| Agent node (hwgeekom) | Same binary, headless role, systemd | Claude Code and Codex CLI session adapters; project and session registry |
| HIL node (hworker) | Same binary plus HIL adapter | Allowlisted lab commands only; hardware interlocks stay outside software |
| Voice remote (P3) | nRF5340 MCU, 3 to 4 PDM MEMS mics, small display | Streams Opus audio over BLE to the iPhone; OFF switch cuts mic power in hardware |

Why the remote talks to the iPhone, not the cloud: the phone is the control plane, so the remote stays a simple, low-power mic. The phone's STT, policy, and approvals cover it for free.

## Pairing, security and authorization

Every device has its own key pair, and the relay only ever sees ciphertext. Authority comes from signed events from trusted inputs, never from model output.

Pairing (about one minute, no IP entry):

- The desktop shows a QR code holding its public key, a one-use token (expires in 2 minutes), and the relay room ID.
- The iPhone scans it and opens a Noise XX handshake through the relay, or over LAN when mDNS finds the PC.
- Both screens show the same 4-word phrase. You confirm on both.
- The phone stores the device in its registry with a role (text receiver, agent, or both) and a capability list.
- Revoke on the phone takes effect at once. The relay drops the room and the key is deleted.

Transport: LAN direct when possible, relay otherwise. Both use the same Noise session, so security does not depend on the network. There are no open inbound ports.

Authorization (from the Product Definition, unchanged):

| Tier | Trigger | Runs |
| --- | --- | --- |
| 1 Suggest | Inferred from speech | Nothing until you tap |
| 2 Command | Wake phrase or PTT | Only actions in a granted scope |
| 3 Sensitive | Send, pay, delete, actuate, disclose | Only after Face ID or passcode on the phone |

- Grants are scoped by device, project, capability, risk class, and expiry. There is no global "always allow".
- `activation_kind`, `authenticated_actor`, and `granted_scope_id` are set only by the phone's input and policy code. The LLM cannot write them.
- Every command gets an idempotency key, so a reconnect never runs a task twice.
- An append-only audit log lives on the phone, with an encrypted copy on the relay.

Privacy defaults (proposed): raw audio is never stored. Transcripts stay on the phone for 7 days. Cloud STT is used only when the routing rules call for it, and the app shows when it is in use.

## Repo, stack and extensibility

One monorepo holds the whole project in your standard top-level layout (AI, DOCS, FW, HW, SW, SYS). The protocol schema in SYS is the contract that every client is generated from. Extensibility comes from five plugin interfaces, so adding a user, engine, agent, or device never touches the core.

```
voiceremote/
  .github/workflows/  # CI: ios (macOS runner -> TestFlight), desktop, relay, fw, bench
  SYS/                # ground truth: product definition, this design, requirements [REQ-n] [D-n] [Q-n],
                      #   protocol + tool schemas, security and safety model, system test plans
  HW/                 # remote PCB and mic array (KiCad), enclosure and stand CAD, fixtures/
  FW/                 # remote firmware (nRF5340, Zephyr) + host tools + docs/characterisation/
  SW/
    ios/              # App, KeyboardExt, LiveActivity, Packages/Core, Stt, Brain (prompts)
    desktop/          # Rust: core, inject-windows, inject-linux, agents, app (Tauri, headless)
    relay/            # Cloudflare Worker + Durable Objects
    bench/            # STT + brain benchmark tools, curated phrase/command sets (LFS audio)
  DOCS/               # external references only: Apple/vendor docs, datasheets, standards
  AI/                 # AI workspace, mirrors disciplines: AI/SYS, AI/HW, AI/FW, AI/SW; AI/scratch (gitignored)
  AGENTS.md  CLAUDE.md  README.md
```

Release trains: `ios-v*` (TestFlight build), `desktop-v*` (Windows and Linux installers), `relay-v*` (Worker deploy), `fw-v*` (remote firmware), `hw-v*` (fab package). Codex task specs are drafted in `AI/SYS/` and promoted to `SYS/` once you review them.

| Plugin interface | Adds | First implementations |
| --- | --- | --- |
| `SttEngine` | Speech engines | Apple, Argmax Parakeet, WhisperKit, ElevenLabs, AssemblyAI |
| `LlmBrain` | Control AI models | Apple Foundation Models, MLX or llama.cpp open models, Claude API |
| `CaptureSource` | Microphones | iPhone mic, AirPods, Windows mic, voice remote |
| `Target` | Places text or tasks can go | iOS keyboard, Windows field, Linux field |
| `AgentAdapter` | Agent providers | Claude Code, Codex CLI, cloud agents, HIL |

For other users later: every record already carries an `account_id`, and the relay is multi-tenant by room. Opening it up means adding sign-up and billing for cloud STT, with no change to the protocol.

## Plan

P0 is cut into 9 Codex tasks, each with its own test. Later phases start only when the gate above them passes.

Each task is one Codex run on hwgeekom with a written spec, and it must pass its "Done when" check before the next task starts. iOS tasks need a Mac or a macOS CI runner to build and sign (see Risks).

| # | Phase | Codex task | Done when |
| --- | --- | --- | --- |
| 1 | P0 | Protocol schema + codegen (Swift, Rust, TS) | Round-trip tests pass in all 3 languages |
| 2 | P0 | Relay: rooms, Noise passthrough, presence, APNs | 2 test clients exchange messages across networks; relay sees only ciphertext |
| 3 | P0 | Desktop core: pairing, LAN + relay session | QR pair under 1 min; revoke fails the next message |
| 4 | P0 | Windows text injection + focus report | Text lands in Notepad, Chrome, Teams; never presses Enter |
| 5 | P0 | Linux text injection (X11, Wayland portal, uinput) | Same test on GNOME Wayland and X11 |
| 6 | P0 | iPhone app: capture, pairing, device list, target picker, Dictation/AI Control toggle, history | AirPods stay on the phone while typing goes to the PC |
| 7 | P0 | `SttEngine` + Apple, Argmax, WhisperKit, cloud engines + cleanup pass | All engines stream partial and final text into the app |
| 8 | P0 | Benchmark kit: record 200 phrases, score engines | Report picks the engine against the gate |
| 9 | P0 | iOS keyboard extension | Dictated text appears in Messages and Mail; no auto-send |
| 10 | P1 | LLM brain (cloud) + on-device fast path, suggestion cards, wake phrase | Suggestions show; nothing runs without a tap |
| 11 | P1 | Policy gate, scoped grants, Face ID, audit log | Tier 3 actions always ask for Face ID |
| 12 | P2 | Agent adapters: Claude Code, Codex CLI, cloud | "Ask the arm-design session..." reaches the right session |
| 13 | P2 | Routing rules, offline hold, cloud fallback | Offline laptop task shows a hold, not a fake success |
| 14 | P3 | Remote dev-kit rig + BLE audio + source scoring | Benchmark vs AirPods and iPhone mic |
| 15 | P4 | HIL adapter design + safety review | Written review approved before any code |

## Learnings from open-source dictation apps

Two MIT apps already solve the hard desktop parts, so we should reuse their code instead of rebuilding it. None of them has an iPhone app or keyboard, so that part is still new work.

| App | Platforms | Engines | Worth taking |
| --- | --- | --- | --- |
| [Hex (anomalyco, Rust)](https://github.com/anomalyco/hex) | macOS; Windows and Linux beta | Parakeet, Whisper (local) | Name and spelling fixes before paste, per-app modes, sandboxed transforms, 7-day text history with no audio, rewrite that falls back to the raw transcript |
| [Handy (Tauri)](https://github.com/cjpais/Handy) | Windows, macOS, Linux | Parakeet, Whisper GGML | Clipboard paste that restores the old clipboard, Linux injector fallbacks, Silero VAD, CLI/signal triggers |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | macOS | whisper.cpp, Parakeet | Modes picked by app or URL, personal dictionary (GPL, so ideas only, no code) |

- Wayland is the weak spot. Both apps need fallbacks (wtype, dotool, RemoteDesktop portal), and Handy reports wtype failing on Ubuntu 26.04 GNOME. Test Linux on your real desktop early.
- Paste beats simulated typing. Clipboard paste with a short delay and clipboard restore is the most reliable path. Keystroke typing is the fallback.
- Keep the overlay out of focus. An overlay that takes focus breaks the paste.
- Define the trigger rules once: hold to talk, double-tap to lock, ignore taps under 300 ms. Use the same rules on the phone, the remote, and the desktop.
- Expose a CLI trigger (`voice``remote`` dictate toggle`) so OS hotkey tools and scripts can drive it.
- The LLM rewrite must be optional and fail-safe. If it fails, paste the raw transcript.
- Store text, not audio, with capped retention. This matches our privacy default.

Plan change: the desktop injection crates start from Hex and Handy's MIT code, with credit, instead of from scratch.

## Risks and open questions

The biggest risk is iOS background limits, because the phone is the control plane. P0 tests this first on a real device.

| Risk | Impact | Mitigation |
| --- | --- | --- |
| iOS suspends the app while it routes tasks | Commands stall when the phone is locked | Live Activity plus an active audio session while listening; relay holds task state; APNs wake |
| Action Button cold start is unreliable | Slow first word | Test on device in week 1; fall back to Lock Screen control or Live Activity button |
| On-device engine does not beat Apple on your voice | Main goal missed | Benchmark gate; cloud engine plus vocabulary and cleanup layers |
| Wayland blocks synthetic typing | Linux receiver fails on some desktops | RemoteDesktop portal first, uinput fallback, clipboard paste last |
| Argmax Pro SDK license cost or terms | Blocks lead engine | WhisperKit (MIT) as open fallback |
| Battery and heat in continuous mode | Phone unusable all day | Voice activity detection gates STT; cloud offload when hot |

Build blocker: iOS apps can only be built and signed on macOS. Codex on hwgeekom can write the Swift code, but a GitHub Actions macOS runner builds, signs, and ships to TestFlight (decided). This needs an Apple Developer account ($99 a year).

Open questions for later phases (not blocking P0):

- Wake phrase wording, and whether it can be changed
- Transcript retention: is 7 days on the phone right?
- Which actions are pre-approved per project, and for how long
- Whether the remote's button can approve medium-risk actions
- Budget for the Argmax license and cloud STT

## Sources

- Voice Control Fabric Product Definition v0.2
- [Gigazine: Apple SpeechAnalyzer benchmark (Jul 2026)](https://www.gigazine.net/gsc_news/en/20260714-apple-speech-analyzer-benchmark/)
- [Argmax blog: SpeechTranscriber, WhisperKit, Parakeet on Pro SDK](https://www.argmaxinc.com/blog)
- [FutureAGI: best voice AI, July 2026](https://futureagi.com/blog/best-voice-ai-july-2026/)
- [Telnyx: best speech-to-text engine](https://telnyx.com/resources/best-speech-to-text-engine.md)

- [Hex (anomalyco)](https://github.com/anomalyco/hex), [Hex legacy (kitlangton)](https://github.com/kitlangton/Hex), [Handy](https://github.com/cjpais/Handy), [VoiceInk](https://github.com/Beingpax/VoiceInk), [awesome-voice-typing](https://github.com/primaprashant/awesome-voice-typing)

