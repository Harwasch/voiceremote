```mermaid
flowchart LR
    Fixtures[Shared synthetic JSON] --> Decode[Typed decode]
    Decode --> Encode[Validated encode]
    Encode --> Compare[Compare JSON values]
```

| File | What it is | Status |
|---|---|---|
| [RoundTripTests.swift](RoundTripTests.swift) | Valid/invalid shared vectors and constructed-value checks | ✅ Linux |

Start with the tests; the corpus is located relative to the source file, so run
from any directory in the checkout. Trace: product §4/§7; `[REQ-n]` is TBD.
