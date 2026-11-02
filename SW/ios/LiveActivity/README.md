```mermaid
flowchart LR
  Spec[../project.yml] --> Component[LiveActivity]
  Component --> CI[macOS CI]
```

| File | What | Status |
|---|---|---|
| [VoiceRemoteActivity.swift](VoiceRemoteActivity.swift) | Activity attributes, lock-screen and Dynamic Island view stub. | 🟡 macOS build unverified |

Start with the linked file; see the [iOS map](../README.md) for design and validation.
