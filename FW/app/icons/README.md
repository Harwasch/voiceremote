# Orb sparkle

```mermaid
flowchart LR
    Mock[Mock AI cubic path] --> Generate[generate.py + Pillow]
    Generate --> A8[sparkle.c: 112 x 112 A8]
    A8 --> UI[ui.c: tint / scale]
    Primitives[LVGL lines / arcs / circles] --> UI
```

| File | Purpose | Status |
|---|---|---|
| `generate.py` | Supersample the supplied mock's four cubic curves; no external artwork | ✅ Reproduced |
| `sparkle.c` | 12,544-byte alpha mask, tinted black/grey/mode colour by LVGL | ✅ PNG/IDF verified |

Purpose: preserve the mock sparkle without triangle antialiasing seams. Inputs:
`icon('ai')` in the owner-supplied mock; Pillow. All other icons use LVGL primitives,
including Bluetooth, mic-off, hold, record, type, Auto badge, bin, X and check.
Panel sharpness remains unverified. [REQ-8]/[REQ-18] display support only.

Regenerate from the repo root: `python3 FW/app/icons/generate.py`.
