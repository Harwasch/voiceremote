```mermaid
flowchart LR
  Transcript[Untrusted transcript] --> Router[BrainRouter]
  Router --> Local[BrainApple adapters] & Cloud[ClaudeBrain via relay proxy]
  Local & Cloud --> Codec[Generated Protocol tool codec]
  Codec --> Proposal[BrainProposal]
  Proposal --> Cards[SuggestionEngine cards]
  Cards -->|UI tap on exact revision| Review[TappedSuggestion]
  Review -. separate integration .-> Policy[Policy package]
  Proposal --> Bench[BrainBenchmark run export]
```

| Path | What | Status |
|---|---|---|
| [Package.swift](Package.swift) | Plain Swift 6 + generated Protocol dependency; no Policy/Core dependency | ✅ Linux |
| [Sources/](Sources/README.md) | Strict tool inputs, tolerant provider metadata, refusal outcomes, bounded whole-transcript suggestions | ✅ Synthetic Linux tests |
| [Tests/](Tests/README.md) | Authority, current-shape fake server, refusal, streaming races, retention/rate caps and cancellation | ✅ Linux |
| [INTEGRATION.md](INTEGRATION.md) | Policy handoff, assumptions, provider sources and verification limits | 🟡 Integration pending |

Start with [LlmBrain](Sources/LlmBrain.swift), then [SuggestionEngine](Sources/SuggestionEngine.swift).
Run `swift test -j 4 --package-path SW/ios/Packages/Brain`; scoped: append `--filter Suggestion`.
Trace: [REQ-31/33/36–40](../../../../SYS/requirements.md). Tests prove portable behavior only.
Live Claude, Apple/MLX, real-device accuracy/latency/battery, visible app cards and Policy integration are **unverified**.

Fenced JSON in model text stays **dropped**, never parsed into a tool call. Claude accepts only
native `tool_use.input` through the generated codec; Apple/MLX text must be a bare JSON array.
Provider metadata is ignored. A refusal produces no proposals and never reruns on another brain.
