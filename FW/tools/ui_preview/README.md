# Native Orb preview

```mermaid
flowchart LR
    Fixtures[main.c: synthetic phone / input / touch] --> UI[real app/ui.c + assets]
    UI --> LVGL[managed LVGL 9.5.0 software renderer]
    LVGL --> Strip[stub board: RGB565 DMA strip]
    Strip --> PNG[build-preview/*.png: physical screen mask]
```

| File / output | Purpose | Status |
|---|---|---|
| `run.sh`, `CMakeLists.txt` | Native C/C++ build; four compiler jobs maximum | ✅ Root runnable |
| `main.c` | Runtime/board stubs, synthetic fixtures, PNG writer and interaction checks | ✅ Native verified |
| `preview_runtime.h`, `stubs/` | ESP-free UI runtime boundary | ✅ No board access |
| `lv_conf.h` | LVGL software renderer and lodepng; no GPU/window system | ✅ Native verified |
| `../../build-preview/*.png` | Eleven round states and one 240×280 physical-slider state | ✅ Generated; ignored |

Purpose: inspect the actual firmware UI without a panel. Inputs: bundled Lexend
subsets and `FW/managed_components/lvgl__lvgl`; no separate mock renderer.
Start from the repo root (CMake, C/C++ compiler):

```sh
heavy bash FW/tools/ui_preview/run.sh
```

LVGL must already exist from the [firmware dependency setup](../../README.md).
Missing source produces a clear CMake error; the tool never downloads dependencies.
Everything generated goes into ignored `FW/build-preview/`.

| PNG basename | Fixture |
|---|---|
| `off.png`, `ptt-armed.png` | Hollow grey / outlined transcribe orb |
| `ptt-listening-transcribe.png`, `rec-listening-ai.png` | Filled orb and pulse from explicit producer streaming bit |
| `auto-target.png`, `named-target.png` | Resolved destination, Auto badge, pips |
| `long-name.png`, `error-text.png` | Shrink/ellipsis and temporary red error |
| `no-link.png` | Hollow grey orb and Bluetooth-off pairing target |
| `pairing-number.png`, `forget-confirm.png` | Numeric comparison / bin confirmation |
| `rectangular.png` | 240×280 physical-slider layout; no capture ring |

![Orb preview](../../build-preview/ptt-armed.png)

`run.sh` first executes `ui_preview --check`: actual pointer input, direct capture
selection, mode/target events, cancelled/recognised 3-second holds, haptics,
pair accept/reject, both modal display guards, failed/successful flush barriers,
error expiry and pulse invalidation bounds. A held PTT with streaming=0 never
pulses; streaming=1 pulses independently of the held level, and clearing the bit
stops it. Fixtures inject the producer bit; this is not a microphone measurement. Pure geometry/listening checks live in
[tests](../../tests/). These support [REQ-8]/[REQ-18]; physical scanout, frame rate,
BLE/input latency, motor feel and panel colour remain **unverified**.
