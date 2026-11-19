```mermaid
flowchart LR
  UI[VoiceRemoteUITests] --> Views[Real app views]
  Views --> Model[AppModel + Policy + Router]
  Demo[DEBUG --ui-demo adapters] --> Model
  UI --> Result[UI.xcresult] --> Export[ci/export_screenshots.py]
  Export --> Gallery[ios-screenshots: named PNGs + index.json + audits]
```

| File / output | What | Status |
|---|---|---|
| [VoiceRemoteUITests.swift](VoiceRemoteUITests.swift) | Light-only flow assertions, largest Dynamic Type main screens, named screenshots and accessibility inventory | 🟡 Apple compile/simulator **unverified** |
| [DemoAdapterProbe.swift](DemoAdapterProbe.swift) | Linux-only real-model/Policy smoke probe using the exact app demo adapters; excluded from Xcode target | ✅ Synthetic Linux probe; UI **unverified** |
| `ios-screenshots` artifact | `gallery__light__default__Main.png` and other labelled PNGs; `index.json` maps files/tests and contains every audit finding | 🟡 Await coordinator `ios-ui-*` run |
| `ios-ui-results` artifact | Full xcresult, including failure diagnostics and XCTest audit attachments | 🟡 Await coordinator run |

Start with `VoiceRemoteUITests.swift` and the [demo adapters](../App/UIDemo.swift).
Inputs: existing app flows and portable contracts. Trace: REQ-3–5/8/16–18/22–25/28–35/56/60.
No new product requirements or device-performance claims.

| Walk | Assertions / review images |
|---|---|
| Startup recovery | Synthetic storage failure shows the real blocked recovery screen; unavailable copy retains the block |
| First run / permissions | Explicit consent; disabled recording; microphone/speech, camera and Bluetooth denied states |
| Talk / destination | Real HOLD gesture; destination exists before capture/first text; Auto/iPhone/computer selection; mode/capture switches |
| Stop | Idle, preparing, listening, finishing, failed and interrupted; OFF/HOLD/CONTINUOUS; no unfinished history commits |
| Devices | Paste synthetic invitation through the system menu; compare four words; confirm then revoke |
| History | Held and unconfirmed text; explicit resend stays visibly unconfirmed |
| Suggestions / Policy | Connected/offline sessions, real scoped grant/revoke, tier 3 exact preview, fake biometric success/refusal, task delivery/completion review/cancel |
| Settings / recorder | Cloud consent off/on/off; withdrawal stops capture; synthetic-only recorder prompt and completion |

Screenshots run in light/default and light/AX5. Audits run once per distinct
navigation/help screen at default size, rather than for every screenshot/state;
the audit itself exercises font sizes. Atomic markers preserve deduplication if
the test runner restarts. Routine CI omits dark. The four tabs plus Settings,
destination picker and approval also run at `.accessibility5`; the debug instrumentation is behind a small disclosure and scales normally. The audit uses Apple's
[`performAccessibilityAudit`](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/performaccessibilityaudit(for:_:))
with **report-only** issue handling: every issue is retained, no finding is waived,
and no accessibility pass is claimed. Audit infrastructure errors fail the test.
System share/Files sheets, actual audit restoration, OS permission prompts and hardware
acceptance are **unverified**; synthetic adapters do not prove those integrations.

CI uses the separate `VoiceRemoteUI` Debug scheme, unsigned, serial tests and at
most four build jobs. Only `ios-ui-*` tags and manual dispatch run the gallery.
The owner reviews the artifact; this worker does not trigger CI or publish images.

Fault arguments (all require `--ui-demo` and DEBUG): `--ui-first-run`,
`--ui-permission-denied`, `--ui-biometric-refuse`, `--ui-slow-prepare`,
`--ui-slow-finish`, `--ui-capture-failure`, `--ui-interrupt`, `--ui-storage-denied`.
Presentation: `--ui-dark`, `--ui-largest`. Slow adapters await cancellation; they
cannot emit late text after Stop. No network, BLE or LocalAuthentication prompt
is required for these synthetic paths.

Revamp coverage: capture menu and segmented Mode (menu at accessibility sizes); one primary control per state;
Talk gear → Settings; separate Agents tab; invitation/confirmation pairing sheet;
keyboard dismissal and visible four words; History More menu; Phone details and
help sheets. All toggles under test use the native child switch or its trailing
edge, with native value assertions; segmented selection uses `isSelected`, not its empty `value`. Consent also asserts real/saved model state; its
binding is unchanged. OFF cancels every state; Preparing keeps a disabled talk control/spinner and a separate Stop; Finish is only available while recording. Stop also cancels finishing.

`testTalkStateGallery` covers holding, live transcript, continuous, finishing,
Off and Hold-ready in light/default/AX5. Holding preview uses the DEBUG
`--ui-holding-preview` argument through the same phone press handler; the real
hold gesture is tested separately. `--ui-reduce-transparency` previews the custom
Hold control’s opaque fallback; it does **not** set the OS preference (read-only
SwiftUI environment). Native bar preference handling, VoiceOver and motion/haptics
remain **unverified**. Normal demo launches no longer pin Dynamic Type. The forced
AX5 fixture can still produce audit “unsupported font size” findings; no findings
are suppressed. [First-run audit triage](../../../AI/SW/2026-11-04-liquid-glass-research.md#first-run-audit-triage).

UI2 fixes: diagnostics use separately identified expansion buttons; identifiers no
longer replace descendant labels. Tests explicitly expand, scroll and wait for
real/saved consent and destination ordering. The seed capture resets its ordering
flag so a later assertion must observe a new capture. Header waits first bring
Home’s heading into view after Finish. No fixed animation delays are used.

Flows and Stop fault states are separate XCTest cases. Independent default/AX5
main-screen inventories preserve the other tabs after layout assertion failures;
screenshots precede layout assertions and failure helpers attach extra snapshots.
The default baseline runs first; geometry inventory runs only for baseline Home.
AX5 includes lower controls on every tab, pairing words/confirmation, approval
and recorder. Home geometry assertions reject intersecting controls. Debug AX5 is
applied at sheet roots, too. The Linux adapter probe now exercises all five Stop
faults in addition to real Policy approval/refusal. Updated Apple execution and
accessibility acceptance remain **unverified** pending the coordinator’s run.

UI3 performance: successful existence checks return immediately; only genuinely
missing elements poll. State waits have a three-second failure bound. Eight native
fast swipes replace 24/40 slow edge drags; no ScrollView reference survives sheet
dismissal. Keyboard-visible gestures stay above the keyboard. Pairing waits for its sheet to disappear before finding the new device.
Selected default flows may reuse an already-running matching fixture; faults,
approvals and baselines launch fresh. Normal test semantics do not depend on order.
Demo UIKit/SwiftUI animations are off; release and ordinary Debug are unchanged.

Every PNG/audit is checkpointed atomically in the runner container before attaching
to XCTest. [CI export](../ci/README.md) recovers them without a finalized xcresult.
Home cancels Hold when a drag moves beyond 12 points; AX5 scrolling must leave it
idle, and existing hold/release assertions still exercise actual capture. History
uses an explicit full-width menu hit area and flexible row height. New Apple
layout/interaction/timing remain **unverified**; see [UI3 evidence](../../../AI/SW/2026-11-19-ui3-timing.md).

Approved mockup screenshot stems: **Main, Listening, AIControl, Destination,
Approval, History, Devices, Pairing, Agents**. Every stem runs at light/default
and light/AX5; extra screenshots retain descriptive state names. Native filename
prefixes still identify appearance and size. [Translation differences](../App/README.md#approved-mockup-translation).
The suite follows the four real tabs and inline suggestions, capture menus and
explicit sheet Done buttons. Simulator diagnostics are opened under Settings.
Capture selection asserts its accessibility value; native switches still tap the
switch itself and assert values. No fixed sleeps or extra audit passes were added.
The exact DEBUG fixtures pass the portable adapter probe; Apple compilation,
timing, visual match and accessibility acceptance remain **unverified**.
