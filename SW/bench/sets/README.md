```mermaid
flowchart LR
  ReadingPrompts --> OwnerRecording --> EngineOutputs
```

| File | What | Status |
|---|---|---|
| [phrases.json](phrases.json) | 200 prompts: 40 each normal, whispering, fictional names, numbers, tech terms | ✅ Synthetic checks |
| [commands.json](commands.json) | 50 prompts: 10 each of all 5 SYS tool kinds, with fictional registry/context | ✅ Synthetic checks |
| [vocabulary.json](vocabulary.json) | Seed terms and invented names; owner review pending | ✅ Synthetic checks |

Start with the [kit README](../README.md). Purpose: sets for task 8.
Inputs: SYS design/tool contracts and invented text. Verification: synthetic
checks only; real phone performance and owner review **unverified**.
