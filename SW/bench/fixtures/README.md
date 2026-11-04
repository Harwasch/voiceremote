```mermaid
flowchart LR
  InventedInputs --> SyntheticRun --> GateTests
```

| File | What | Status |
|---|---|---|
| [synthetic-run.json](synthetic-run.json) | Two phrases, one command; Apple/pass/fail and correct/incorrect brain fixtures | ✅ Synthetic checks |

Start with the [kit README](../README.md). Purpose: fixtures for task 8.
Inputs: SYS design/tool contracts and invented text. Verification: synthetic
checks only; real phone performance and owner review **unverified**.
