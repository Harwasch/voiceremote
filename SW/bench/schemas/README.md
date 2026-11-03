```mermaid
flowchart LR
  P[Phone export] --> RunSchema --> Scorer
```

| File | What | Status |
|---|---|---|
| [run.schema.json](run.schema.json) | Phone export v1; references SYS tool schema without copying it | ✅ Synthetic checks |
| [gate.schema.json](gate.schema.json) | Owner-editable proposed gate settings | ✅ Synthetic checks |

Start with the [kit README](../README.md). Purpose: schemas for task 8.
Inputs: SYS design/tool contracts and invented text. Verification: synthetic
checks only; real phone performance and owner review **unverified**.

run v1 accepts additive optional `cleaned_text`, ordered `stages` capture-clock offsets, battery `cohort_id`/`conditions`, brain-case `recording_id` and brain-result `transcript`. Existing v1 fixtures remain valid. Ordering/completeness beyond JSON Schema is enforced by benchkit; measurements remain **unverified** until supplied.
