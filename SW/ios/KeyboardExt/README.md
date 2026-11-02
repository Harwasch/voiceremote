```mermaid
flowchart LR
  Spec[../project.yml] --> Component[KeyboardExt]
  Component --> CI[macOS CI]
```

| File | What | Status |
|---|---|---|
| [KeyboardViewController.swift](KeyboardViewController.swift) | Keyboard switch button; full access disabled. | 🟡 macOS build unverified |

Start with the linked file; see the [iOS map](../README.md) for design and validation.
