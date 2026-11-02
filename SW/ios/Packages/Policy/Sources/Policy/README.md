```mermaid
flowchart LR
  Gate[PolicyGate.swift] --> Bio[Biometric.swift]
  Gate --> Audit[Audit.swift] --> Hash[Digest.swift]
  Recovery[AuditRecovery.swift] --> Audit & Bio
  Gate --> Hash
```

| File | Content | Status |
|---|---|---|
| [PolicyGate.swift](PolicyGate.swift) | Risk floors, bounded grants, durable revocation/dismissal, reconnect cancellation, payload-bound approval | ✅ Linux tests |
| [Biometric.swift](Biometric.swift) | Challenge protocol and thin conditional Apple adapter | ✅ Fake tested; Apple **unverified** |
| [Audit.swift](Audit.swift) | Hash chain, exclusive append/sync journal, independent checkpoint + durable append intent, archive-age config | ✅ Linux file and corruption tests |
| [AuditRecovery.swift](AuditRecovery.swift) | Authenticated crash/clock recovery; preserves original bytes and audits repair | ✅ Linux fault-injection tests |
| [Digest.swift](Digest.swift) | SHA-256 and exact preview encoding | ✅ Known-answer tests |

Start at `PolicyGate.submit`. All mutating services run on MainActor; authentication
rechecks state after suspension. Supply a trusted `AuditCheckpointStore`; there is no
unsafe default checkpoint reconstructed from the log. Trace: REQ-28–35, REQ-54–55.

Recovery requires a fresh biometric/passcode challenge and a new gate instance. Checkpoint adapters must persist both the head and exact pending append intent; there is no implicit reset or unexplained-tail acceptance.
