# M5Stack StopWatch (C152)

```mermaid
flowchart LR
    S3[ESP32-S3] -->|QSPI| CO[CO5300: 466 × 466]
    S3 -->|SYS I2C: G47/G48| IO[IOE1 0x4f]
    S3 -->|same bus| PM[PM1 0x6e]
    S3 -->|same bus| TP[CST820B 0x15]
    IO -->|PYG5/PYG8| CO
    IO -->|PYG4 reset| TP
    IO -->|PYG9 PWM| Motor[Haptic]
    Keys[G2 / G1] --> S3
    S3 <-->|I2S G18/17/16/15/21| Mic[ES8311 / analog mic]
    S3 -->|same I2C, 0x18| Mic
    IO -->|pin 3 AU_EN high| Mic
```

| File / resource | Purpose / provenance | Status |
|---|---|---|
| `board.c` | Own IDF C display/control driver + vendor-derived ES8311 register setup / bounded RX DMA | 🟡 Controls owner-confirmed; mic hardware unverified |
| `sdkconfig.defaults` | 16 MB flash, octal PSRAM; UI strip stays internal | 🟡 Hardware unverified |
| `idf_component.yml` | Espressif CO5300 2.2.0, Apache-2.0 | ✅ Offline resolved |
| `BUTTON_GPIOS` in `board.c` | Single mapping constant: G2 yellow/PTT, G1 blue/cycle; logs GPIO edges | 🟡 Colour mapping unverified |

Start at `board_init`; [REQ-8], [REQ-18], [REQ-49–53] not hardware proven.
AU_EN (IOE pin 3) stays high as in vendor `hal_ioe`; amp IOE pin 10 and GPIO 14
are held low before enabling the audio rail. The prototype OFF exception applies;
this is a DMA/encoder stop, with no independent hardware mic cut. No expander reset.
I2C runs at 100 kHz, serially under the app mutex; touch is polled (G13 configured
as input), QSPI uses the Espressif driver macro’s 40 MHz default (vendor uses 80 MHz), TE G38 is an input, not used to synchronize scanout. Driver checks all
initialization writes and stops boot on failure. LCD DMA waits up to 1 s/strip.

Source inputs (prefetched read-only references; none executed):

| Vendor source | Facts reused |
|---|---|
| [UserDemo](https://github.com/m5stack/M5StopWatch-UserDemo), `main/hal/hal_display.cpp`, `hal_ioe.cpp`, `drivers/cst820/` | QSPI pins, panel command sequence, x gap 6, touch registers/reset |
| [PowerDemo](https://github.com/m5stack/M5StopWatch-PowerDemo), `modules/m5sw_display/`, `modules/m5sw_power/` | Display reset high → rail on → 10 ms → low 8 ms → high 2 ms |
| [M5IOE1](https://github.com/m5stack/M5IOE1), `src/M5IOE1.{h,cpp}` | GPIO mode/pull/drive/output RMW; PWM1 PYG9, 5000 Hz |
| [M5PM1](https://github.com/m5stack/M5PM1), `src/M5PM1.h` | Address 0x6e; power 0x06, I2C config 0x09 |

UserDemo pins M5IOE1 1.0.8, M5PM1 1.0.6, M5GFX 0.2.19; register references
were supplied default-branch clones, so exact tag equivalence is **unverified**.
Vendor uses 468 logical columns with x gap 6; this adapter exposes the requested
466 with the same gap. Alignment, RGB order, touch orientation and scanout are
**unverified** until flashed. Haptic is 20% PWM for 25 ms; perceived strength TBC.
See [licences](../../licences/) for retained MIT and Apache notices.

Reports `virtual_sliders=true`: the shared UI draws the Orb capture ring.

| Mic detail | Source / implementation |
|---|---|
| Bus / pins | Vendor `hal_audio.cpp`: I2C 7-bit 0x18 (driver constant 0x30 is 8-bit), MCLK 18, BCLK 17, ASDOUT 16, LRCK 15, DSDIN 21 |
| Registers | Espressif `esp_codec_dev/device/es8311/es8311.c` supplied inside PowerDemo: open → 16-bit Philips → 16 kHz / 4.096 MHz coefficient → start; MCLK present during reset |
| Route / gain | Vendor analog mic, slave clock, 30 dB gain (`0x16=5`); `0x44=0x58` routes mic left / DAC reference right; only left enters Opus; DAC muted |
| DMA | Stereo 16-bit, 320 stereo samples × four descriptors; nonblocking reads under app mutex; queue-overflow callback fails closed; disable resets DMA cursor and next enable resets RX queue (IDF `i2s_common.c`) |
| Allocation | Encoder state prefers PSRAM, falls back to internal; task stack and DMA stay internal |

The vendor uses 44.1 kHz for its demo; this profile uses the same driver's 16 kHz
clock coefficient. Register values were compared with supplied source; PCM polarity,
left-channel route, clipping/gain, continuous clocks and restart transients are
**unverified** until the coordinator records/plays audio. No speaker playback added.
