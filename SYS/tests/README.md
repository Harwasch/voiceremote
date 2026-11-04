```mermaid
flowchart LR
  Contracts[SYS/protocol] --> E2E[e2e/run.sh]
  E2E --> Worker[Actual relay Worker] & Desktop[Real Rust CLI] & Phone[Swift phone client]
```

| Path | What | Status |
|---|---|---|
| [e2e/](e2e/README.md) | Real WS and LAN pairing, phrase, insertion, queued-frame resume and revoke | ✅ Linux local |

Start: `bash SYS/tests/e2e/run.sh` from repo root. REQ-22–25/61; plan task 2.
