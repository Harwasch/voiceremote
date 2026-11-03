```mermaid
flowchart LR
  LlmBrain --> Router[BrainRouter] --> Claude[ClaudeBrain]
  Claude --> Relay[RelayBrainTransport + Pairing signer]
  Claude --> Decode[ProposalDecoder + generated codec]
  Decode --> Suggestions[SuggestionEngine]
  Suggestions --> Tap[Immutable review snapshot]
  Decode --> Benchmark[BrainBenchmark]
```

| File | What | Status |
|---|---|---|
| [LlmBrain.swift](LlmBrain.swift) | Non-executable proposals, distinct refusal outcome, requests and resource prompts | ✅ Linux |
| [ProposalDecoder.swift](ProposalDecoder.swift) | Bounded JSON envelope reader; original tool bytes to generated codec | ✅ Authority/grammar tests |
| [BrainRouter.swift](BrainRouter.swift) | On-device/Hybrid/Cloud; visible offline and failure degradation | ✅ Linux |
| [RelayBrainTransport.swift](RelayBrainTransport.swift) | Context-checked relay challenge over ClaudeBrain's exact final body; signed request to the same room | ✅ Linux + real local Worker |
| [ClaudeBrain.swift](ClaudeBrain.swift) | Normalized relay-only HTTPS hosts; evolving metadata ignored, tool inputs closed | ✅ Current-shape fake server; live **unverified** |
| [SuggestionEngine.swift](SuggestionEngine.swift) | Whole finalized utterances, segment-local invalidation, plan ordinals, bounded state/inference, edit and tap | ✅ Linux |
| [CommandSequence.swift](CommandSequence.swift) | Conservative linked instructions and ordinal cancellation | ✅ Linux |
| [WakePhraseDetector.swift](WakePhraseDetector.swift) | Configured phrase; ambiguous/meeting/playback → suggestion evidence | ✅ Text tests; acoustic behavior **unverified** |
| [BrainBenchmark.swift](BrainBenchmark.swift) | Run-v1 JSON export without execution/logging | ✅ Synthetic tests; phone bench **unverified** |
| [Resources/](Resources/README.md) | Untrusted-data prompt + tool-schema snapshot | ✅ Bundled |
| [BrainAvailability.swift](BrainAvailability.swift) | Existing shell configuration flag | ✅ Linux |

Start with the interface; [integration contract](../INTEGRATION.md). Trace: REQ-31/33/36–40.

The host selects a model/API version matching relay deployment settings. Proofs add no vendor credential and grant no action authority.

ClaudeBrain bounds HTTP accumulation per response/chunk (1 MiB, 60-second resource timeout), retaining redirect refusal. BrainBenchmark loads the reviewed 50-command set and exports recognized spoken input separately from expected reading prompts. Missing measurements remain TBD; native/provider performance **unverified**.
