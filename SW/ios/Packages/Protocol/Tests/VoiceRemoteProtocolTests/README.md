```mermaid
flowchart LR
    Fixtures[Shared synthetic JSON] --> Decode[Typed decode]
    Decode --> Encode[Validated encode]
    Encode --> Compare[Compare JSON values]
```

| File | What it is | Status |
|---|---|---|
| [RoundTripTests.swift](RoundTripTests.swift) | Shared vectors including archive block/read/page, encode/decode control-cluster rejection and scalar-pattern checks | ✅ Linux |

Start with the tests; the corpus is located relative to the source file, so run
from any directory in the checkout. Trace: product §4/§7; [REQ-59](../../../../../../SYS/requirements.md#extensibility), [REQ-61](../../../../../../SYS/requirements.md#extensibility).

Raw negative fixtures pass their original bytes through both public validation and typed decoding.

Security regressions exercise `"\r\n"`, `"a\r\nb"` and `"\n\u{0301}"`, plus every
forbidden scalar followed by a combining mark, through validation, typed decode and encode.
Base64/hex pattern tests also reject trailing control clusters. Apple execution is **unverified**
until the coordinator reruns macOS CI; the matcher is scalar-based by construction.

Typed round trips include target preparation/readiness, dictation outcome/query and capture-control/result plus their shared negative vectors.

Paired agent inventory, exact-session retained-preview dispatch and durable task queries are generated from SYS/protocol. Shared vectors cover the new typed records and reject added authority fields.
