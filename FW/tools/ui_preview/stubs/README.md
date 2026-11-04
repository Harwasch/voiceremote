# Native board type shim

```mermaid
flowchart LR
    Board[app/board.h] --> Error[esp_err.h: native error type]
    Error --> Preview[ui_preview only]
```

| File | Purpose | Status |
|---|---|---|
| `esp_err.h` | Minimal board return type/constants for the native renderer | ✅ Native built |

Purpose: compile the real UI without ESP-IDF headers. Input: `board.h` return
type. This shim is only on the preview include path; firmware uses ESP-IDF.
Start with [the preview README](../README.md); no hardware compliance claim.
