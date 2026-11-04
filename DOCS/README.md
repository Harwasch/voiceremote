# DOCS: external references only

```mermaid
flowchart LR
    Vendor[Vendor / library sources] --> Licences[licences: retained notices]
    Licences --> FW[Firmware + host tools]
```

| Folder | What | Status |
|---|---|---|
| [licences/](licences/) | Firmware MIT / BSD / Apache / OFL notices and provenance | ✅ Included |

Start with [licence provenance](licences/README.md); engineering results live in `FW/`.
