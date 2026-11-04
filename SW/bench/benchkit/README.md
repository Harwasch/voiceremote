```mermaid
flowchart LR
  I[Run JSON and local SYS schemas] --> Validation --> Scoring --> Markdown
```

| File | What | Status |
|---|---|---|
| [__init__.py](__init__.py) | Package marker | ✅ Synthetic checks |
| [validation.py](validation.py) | Strict JSON, offline schema registry and paired coverage | ✅ Synthetic checks |
| [scoring.py](scoring.py) | Word alignment, term accuracy, timing, battery, gate | ✅ Synthetic checks |
| [cli.py](cli.py) | Report generation and CLI | ✅ Synthetic checks |

Start with the [kit README](../README.md). Purpose: benchkit for task 8.
Inputs: SYS design/tool contracts and invented text. Verification: synthetic
checks only; real phone performance and owner review **unverified**.

Reports include cleanup/delivery/capture-to-field mean/p95 with measured sample counts and battery cohort IDs. Validation rejects reversed or unpaired stage offsets and incomplete spoken-command provenance. Missing measurements stay TBD; tests use synthetic data only.
