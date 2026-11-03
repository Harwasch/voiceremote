# Board adapters

```mermaid
flowchart LR
    App[Shared app/board.h] --> M5[m5stopwatch: ESP32-S3]
    App --> C6[waveshare_c6_169: ESP32-C6 stub]
```

| Folder | Hardware | Status |
|---|---|---|
| [m5stopwatch/](m5stopwatch/) | CO5300, CST820, IOE1/PM1, buttons, ES8311 mic | 🟡 Controls owner-confirmed; audio unverified |
| [waveshare_c6_169/](waveshare_c6_169/) | No pin claims; mic functions return unsupported; encoder allocation is internal RAM | ✅ Compiled stub; hardware unverified |

Start with `app/board.h`, then the selected board's README.
[REQ-49–53] remain unverified; both prototypes report `hw_mic_cut=0`.

The shared app calls only `board_mic_start/stop/read` and `board_audio_alloc`.
StopWatch permits encoder-state PSRAM with an internal fallback; C6 never requests
PSRAM. Both keep the Opus task stack internal. No codec pins leak into shared code.

Panel SPI/DMA belongs to the lower-priority renderer, outside the app mutex.
Touch/IOE/codec I2C remains serialized by the input/audio path. StopWatch QSPI now
matches the vendor’s 80 MHz; CPU/I2C clocks and the C6 stub are unchanged.

Offline recording is StopWatch-only (bit 7); the C6 retains its 4 MiB table and
no offline allocation. StopWatch defaults keep existing NVS/PHY/app offsets,
select the remaining-flash data partition and enable an IRAM-safe I2S ISR.
Generated tables are checked by `FW/tests/check_partitions.py`.
