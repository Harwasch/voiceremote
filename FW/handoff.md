# UI responsiveness handoff — 2026-11-02

```mermaid
flowchart LR
    Touch[Touch + buttons] --> Input[Priority 5: poll / debounce / audio transport]
    Input --> Mailbox[Short app-mutex snapshot]
    Mailbox --> Render[Priority 1: LVGL + synchronous panel DMA]
    Encode[Priority 4: Opus] --> Input
    Phone[Phone write] --> Barrier[40 ms wait / app mutex released]
    Barrier --> Render
    Render -->|completed matching DMA| Apply[Existing security / ack / epoch checks → response]
```

Purpose: hand off UI latency/audio-isolation changes against `c712529`. Inputs:
production firmware, native LVGL fixtures, ESP-IDF 5.5.6, supplied vendor sources.
Host logic/render checks and both board builds are verified; perceived latency,
sustained audio and power **need hardware to tell**. No hardware/adapter/serial,
flash, commit, push, PR or additional review was used. Earlier Stage 2 evidence
is retained below as history.

| Likely cause | Finding / action | Evidence / remaining measurement |
|---|---|---|
| Whole-screen invalidation / synchronous refresh | Confirmed by source. Normal changes now invalidate old/new capture sectors, Orb, or target; initial draw, overlay transitions and failed-flush recovery remain full screen | Native destination update: **44,270 pixels**, y=356..450, versus 466×466 = **217,156** full screen. Partial transitions equal forced full redraws; device time needs hardware to tell |
| Touch debounce / release | Confirmed: selection previously waited for release, then 25 ms debounce. Capture/Orb now preview existing selected styles on down, roll back when cancelled; accepted release + debounce still emits the event | Pure gesture tests and real-UI native checks include first 5 ms sample, rollback, unchanged state before release/filter, dead zones and direct PTT→OFF |
| Touch polling cadence | Additional source finding: `ui_tick` ran each pass, but LVGL's input timer used `CONFIG_LV_DEF_REFR_PERIOD=33` ms (`src/indev/lv_indev.c:132`) | Touch now samples in the main loop independently of LVGL, with the existing 5 ms delay per pass; actual cadence is work + delay. `touch_poll` and `period` log the bus/loop cost |
| Rendering under audio/input mutex | Confirmed by source. Renderer uses an immutable snapshot and holds no app mutex during LVGL or DMA; input/transport priority 5 > encoder 4 > renderer 1, without core pinning | Native flush asserts lock depth zero and interleaves input during DMA. Existing transport/gate tests pass. C6 builds; its display/mic remain stubs. Sustained audio/UI coexistence needs hardware to tell |
| CPU 160 vs 240 MHz | Both generated configs remain **160 MHz**, PM disabled. Vendor UserDemo selects 240 MHz; no CPU clock change made pending measurements | Vendor `sdkconfig.defaults:10`; built `CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ=160` on S3/C6. No CPU-frequency power increase; battery effect of the overall change needs hardware to tell |
| QSPI / shared I2C | QSPI **40→80 MHz**, matching vendor panel/pins. I2C remains **100 kHz**, matching vendor CST820 driver. Reset retries/readback are untouched | [UserDemo at supplied revision](https://github.com/m5stack/M5StopWatch-UserDemo/tree/81099c784991dc77f522de1a5bf62ec5de9ae0b5): `main/hal/hal_display.cpp:83`, `main/hal/drivers/cst820/cst820.cpp:25`. Higher switching rate / shorter wire time can affect power in opposite directions; net current/battery delta **TBC**, needs hardware to tell |
| 16-line strip / software antialiasing | Retained one internal 16-row RGB565 DMA strip, no PSRAM dependency; no speculative cache or larger buffer | Redraw wall time plus DMA-strip mean/max let hardware separate transport from other redraw work. Whether arcs/icons dominate **needs hardware to tell**; no desktop timing is used as device evidence |
| 268×268 pulse at 5 Hz | Retained visual design and bounds; each redraw uses one frozen phase across strips | Native test flushes **359,120 pixels in 1 s** = five 268×268 regions, bounds (99,99)..(366,366). On-device cost **needs hardware to tell** |

All twelve synthetic fixture PNGs are byte-identical to the baseline. Audio
framing, arm rules, producer-only listening indication and SYS files are unchanged.
Linked target taps remain inert; existing modal/haptic actions still accept release.

The REQ-18 barrier hands a candidate to the renderer, releases the app mutex,
and waits up to 40 ms on a semaphore. Success requires the same request's completed
synchronous DMA, no intervening modal/cancellation, and elapsed time below 40 ms;
BLE rechecks security before applying the phone state. A failed/late draw returns
an ATT error, disarms as before, and restores the authoritative view on the next
render pass. A new control epoch during the wait still prevents arming.

Notification pacing remains one data submission per main-loop pass. In the pinned
ESP-IDF source, `ble_gattc.c:5512–5575` calls `ble_gap_notify_tx_event` from
`ble_gatts_notify_custom`; `ble_gap.c:11436–11455` and `:1310–1324` deliver this
inline once CONNECT has been delivered. It is a submission result, **not a radio
acknowledgment**. Thus app-task notifications can retire their existing pending
slot while the host is waiting. No nested host event pumping or transport-policy
change was added. The 40 ms budget is an engineering assumption below the four
20 ms packets' 80 ms horizon, **not proof of link headroom**; scheduling, HCI flow
control, slow I2C and mutex reacquisition still need hardware to tell. Rejections
are logged for tuning; a stalled panel cannot cause a successful display ack.

`REMOTE_TIMING` defaults **ON**, including both final build caches. One `timing`
line every five seconds, from the low-priority renderer, reports:

| Field | Meaning |
|---|---|
| `redraw=mean/max n=` | Wall µs for passes that actually flushed, including DMA waits and preemption; idle passes excluded |
| `touch_to_dma_est=mean/max n=` | Millisecond-resolution touch sample → last successful DMA for a changed capture/Orb preview, expressed in µs; excludes physical contact before sampling and panel scanout. Previews cancelled before drawing are excluded |
| `loop`, `period` | Mean/max µs of main-loop work including lock wait, and start-to-start interval including the 5 ms delay |
| `touch_poll`, `dma_strip` | Mean/max µs of touch I2C read and each panel flush including RGB565 swap/wait; DMA count `n` allows comparison of total DMA time against total redraw time |
| `queue_high` | Maximum encoded packets observed during the interval, out of four; existing per-segment encoder/drop/heap metrics remain |
| `flush_errors`, `barrier`, `rejects` | Failed redraw passes, mean/max phone barrier µs and unsuccessful requested barriers |

No per-frame log, audio contents, transcripts, target names or credentials.
`-DREMOTE_TIMING=OFF` compiles out the probes/log; S3 OFF build succeeded and the
ELF contained no `timing_*` symbols. Runtime stack/heap and timing remain **TBC**.

| Bytes | S3 baseline | S3 now | Delta | C6 baseline | C6 now | Delta |
|---|---:|---:|---:|---:|---:|---:|
| Total image | 1,158,645 | 1,151,369 | −7,276 | 1,231,534 | 1,224,080 | −7,454 |
| Padded `.bin` | 1,158,768 | 1,151,488 | −7,280 | 1,231,872 | 1,224,416 | −7,456 |
| DIRAM used | 171,747 | 173,251 | +1,504 | 154,394 | 156,236 | +1,842 |
| `.bss` + `.data` | 77,492 | 78,996 | +1,504 | 67,804 | 69,308 | +1,504 |
| DIRAM remainder | 170,013 | 168,509 | −1,504 | 297,718 | 295,876 | −1,842 |
| Runtime internal heap delta | TBC | TBC | TBC | TBC | TBC | TBC |

Baseline builds were checked/rebuilt and `idf.py size` recorded before edits;
final values use the same generated configs and timing ON. Link-time remainder
is not runtime free heap. The S3 renderer adds an **8,192-byte internal task stack**
plus task/semaphore overhead at runtime; exact net heap delta needs hardware to
tell. The C6 stub allocates no renderer task while `operational=false`. No strip
size increase, framebuffer cache or shared PSRAM allocation was added. Smaller
images follow removal of the unused LVGL input/timer path; no size target claimed.

Verification: `heavy bash FW/tests/run.sh` passes all four suites (**700** control/
layout/gesture checks, **373** audio transport checks, **4** Python wire tests,
**9** Python audio tests). `heavy bash FW/tools/ui_preview/run.sh` passes all
12 states and added preview/rollback, partial/full equality, lock-free DMA,
interleaved input, modal cancellation, failed/late/no-render barrier checks.
Both S3 and C6 builds succeed with `VR_TIMING=1`, CPU 160 MHz. Native interleaving
checks model scheduling boundaries; they do not establish RTOS/radio timing.

Reproduce from the repository root with the [README toolchain setup](README.md)
(and the supplied offline mirror variables in the shell only), one heavy job at
a time and no more than four build workers:

```sh
heavy bash FW/tests/run.sh
heavy bash FW/tools/ui_preview/run.sh
heavy idf.py -C FW -B FW/build-m5 -DIDF_TARGET=esp32s3 -DREMOTE_TIMING=ON reconfigure
heavy cmake --build FW/build-m5 -j 4
heavy idf.py -C FW -B FW/build-m5 build
heavy idf.py -C FW -B FW/build-m5 size
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 -DIDF_TARGET=esp32c6 -DREMOTE_TIMING=ON reconfigure
heavy cmake --build FW/build-c6 -j 4
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 build
heavy idf.py -C FW -B FW/build-c6 size
```

Coordinator-only flash command, **not executed**:

```sh
heavy idf.py -C FW -B FW/build-m5 -p /dev/ttyACM0 flash
```

Hardware pass: tap/drag/release each sector and Orb, exercise both buttons while
streaming, change phone destinations during pulse/encoding, and open/cancel both
modals. Collect the five-second timing lines with existing audio segment stats;
check no queue overflow/disarm/drop under UI load, target barrier rejections,
real display visibility, stack/heap, touch-I2C latency and stability of 80 MHz QSPI.
Compare battery current with the old build on the same board/workload. The
remaining subjective lag, whether antialiasing dominates and net power impact
**need hardware to tell**. The first microphone initialization and I2C fault paths
can still block their existing input/audio mutex; they are not redraw work.

# Stage 2 handoff — 2026-11-02

```mermaid
flowchart LR
    ES[ES8311 left mic / 16 kHz] --> Opus[Fixed-point Opus: 320 samples]
    Opus --> Queue[4 packets / 512-byte bound]
    Queue --> Framer[Actual MTU / START + END + LAST]
    Framer --> Client[BlueZ client / current-ack arm]
    Client --> WAV[One 16 kHz mono Int16 WAV per segment]
    Host[Native logic + C/Python round trip] --> Framer
    Builds[S3 + C6 builds] --> Pending[Coordinator: hardware measurements / playback]
```

Purpose: reproducible Stage 2 handoff. Inputs: current `SYS/protocol/remote-ble.md`,
owner-confirmed control/Orb baseline `dd3db68`, supplied vendor sources and offline
component/Python caches, ESP-IDF 5.5.6. Host framing/codec/render/build checks are
verified; **new on-device audio, heap and timing remain unverified**. Existing
pairing/buttons/touch/Orb were confirmed by the owner before this change.
No flash, serial device, Bluetooth adapter, commit, push, PR or extra review used.

| Change | Entry point |
|---|---|
| Mic / allocation | `boards/m5stopwatch/board.c`: vendor ES8311 register setup, I2C 0x18, G18/17/16/15/21, analog left mic, 30 dB; AU_EN high, both speaker enable lines low; four RX DMA descriptors. C6 mic returns unsupported, allocation internal only |
| Codec / queue | `app/audio.h`, `audio.c`, `audio_runtime.c`: fixed-point mono 16 kHz / 20 ms raw Opus, starting 24 kbit/s CBR / complexity 0, max 512 bytes; dedicated 48 KiB internal-stack task, four-packet queue |
| Transport / gate | Actual `ble_att_mtu()` per frame, segment starts 1 and never reuses IDs; END/sequence exhaustion; arm + local not OFF + PTT for hold; subscription/security/info/snapshot prerequisites retained |
| OFF / failures | RX disable and task suspension immediately under app mutex; old computation resumes only for a new generation, then its output is discarded. No queued data flush. END reserved slot, then stopped Input; END failure disconnects after 1 s. Overflow/notify failure requires resync + a fresh trigger |
| UI | Producer sets `input.streaming` after first accepted data notification, clears on stop; Orb and Input read the same bit. Preview checks it independently of PTT |
| Version / link | 0.2.0; name `Voice Remote`; S3 caps 0x3f, `hw_mic_cut=0`, maximum packet 512; C6 capabilities remain zero because it is a stub. Requests MTU 247, 15–30 ms interval, zero latency, 4 s supervision; phone/OS decides |
| Client | `tools/ble_client/{client,wire,audio}.py`: fresh-snapshot recovery, coalesced current-ack writes after every Input, `--arm` follows local capture/mode, WAV decode, duplicate/loss checks and 1 s watchdog, including missing START |

At most one data notification is pending in NimBLE plus one reserved empty END.
Data already accepted by the controller cannot be retracted on OFF; no new data
notification is submitted after OFF. Queued tail packets own frame sequences, so
an END following discarded tail data produces a reported gap rather than a splice.
There is no tap-lock, PLC, FEC, DTX, audio storage or audio-content serial logging.

| Verification | Result |
|---|---|
| `heavy bash FW/tests/run.sh` | Four ctest suites pass: 687 control/layout C checks, 373 transport C checks, 4 Python wire cases and 9 Python audio cases. Suites cover control/layout, Python wire, fake-encoder transport, Python reassembly/codec/WAV. C transport covers MTU 23/247, frame flags, arm/hold/OFF, queue overflow, MTU changes and ID/sequence exhaustion; C/Python round trips also use MTU 64/517 |
| `heavy bash FW/tools/ui_preview/run.sh` | All 12 PNG states and pointer/render-barrier/pulse checks; producer bit controls listening |
| S3 and C6 build commands below | Both succeed; C6 remains build-only |
| Locked uv Python tests below | Wire, recovery, duplicate/conflict/gap/watchdog and WAV cases pass (13 total); real libopus round trip, no C development headers |

Static baseline `idf.py size` was run **before edits**, rebuilding the stale C6
UI object first. Final size uses the same build configurations plus GATT-client
support needed to request MTU exchange. Image sizes exclude `.bin` padding.
These link-time remainders are **not free runtime heap**.

| Bytes | S3 before | S3 after | Delta | C6 before | C6 after | Delta |
|---|---:|---:|---:|---:|---:|---:|
| Total image | 968,837 | 1,158,317 | +189,480 | 1,036,470 | 1,231,534 | +195,064 |
| Padded `.bin` | 968,960 | 1,158,432 | +189,472 | 1,036,816 | 1,231,872 | +195,056 |
| DIRAM used | 166,591 | 171,739 | +5,148 | 151,574 | 154,394 | +2,820 |
| `.bss` + `.data` | 73,980 | 77,484 | +3,504 | 65,612 | 67,804 | +2,192 |
| DIRAM remainder | 175,169 | 170,021 | −5,148 | 300,538 | 297,718 | −2,820 |
| Runtime internal heap before/after/delta | TBC | TBC | TBC | TBC | TBC | TBC |
| Runtime PSRAM before/after/delta | TBC | TBC | TBC | No PSRAM | No PSRAM | N/A |

Both images fit the existing 1,536,000-byte app partition. Once per segment serial
logs encoder mean/max µs, queue high-water, known dropped encoded frames, notify
failures, source error code, free internal and PSRAM heap + deltas from segment start, CPU Hz and
encoder stack watermark. Boot logs allocation deltas across encoder/task creation.
The first mic start allocates I2S/DMA and is visible in its segment heap delta.
Capture-overflow loss counts beyond known discarded packets remain unknown.

Both current configs select 160 MHz; S3 has two cores and PSRAM while C6 has one
core and no PSRAM. S3 encode timings include its own architecture/memory/scheduler
and cannot establish C6 capacity by clock scaling. C6 links the same fixed-point
code with internal allocation but cannot capture until its real driver lands.
Compare frame time against the chosen 20 ms profile on each named board; throughput,
heap sufficiency, acoustic quality, power and sustained MTU-23 capacity are TBC.

Run from the repository root; setup in [README](README.md), at most four compiler
jobs and one heavy job at a time. Offline mirror/cache environment belongs only in
the shell; sandbox metadata overlay after IDF export is `/tmp/voiceremote-espressif`.

```sh
heavy bash FW/tests/run.sh
heavy bash FW/tools/ui_preview/run.sh
heavy idf.py -C FW -B FW/build-m5 -DIDF_TARGET=esp32s3 reconfigure
heavy cmake --build FW/build-m5 -j 4
heavy idf.py -C FW -B FW/build-m5 build
heavy idf.py -C FW -B FW/build-m5 size
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 -DIDF_TARGET=esp32c6 reconfigure
heavy cmake --build FW/build-c6 -j 4
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 build
heavy idf.py -C FW -B FW/build-c6 size
UV_CACHE_DIR=/tmp/voiceremote-uvc-s2 UV_OFFLINE=1 UV_LINK_MODE=copy uv run --project FW/tools/ble_client python -m unittest discover -s FW/tools/ble_client -p 'test_*.py' -v
```

Coordinator-only flash command, **not executed**:

```sh
heavy idf.py -C FW -B FW/build-m5 -p /dev/ttyACM0 flash
```

Coordinator-only recordings (substitute scanned address; choose fresh file prefixes):

```sh
uv run --project FW/tools/ble_client python FW/tools/ble_client/client.py --address AA:BB:CC:DD:EE:FF --capture 1 --recording 1 --arm --save /tmp/ptt.wav --seconds 60
uv run --project FW/tools/ble_client python FW/tools/ble_client/client.py --address AA:BB:CC:DD:EE:FF --capture 2 --recording 1 --arm --save /tmp/rec.wav --seconds 60
```

PTT: select PTT, release then hold yellow and speak, release to close. REC: start
OFF, wait for connection/snapshot, deliberately select REC, then OFF to close.
The phone options do not move physical controls. Files are `ptt-seg00000001.wav`,
etc.; loss adds `-interrupted.wav`, preserves earlier PCM for diagnosis and reports
gap events. The client never silently joins later audio or overwrites a file.
It retains provisional short PTT presses for bench listening, with no STT/actions.

| Assumption / contract question | Handling |
|---|---|
| Prototype hardware cut | Owner's documented exception; AU_EN stays powered, `hw_mic_cut=0`. No [REQ-49] hardware compliance claim |
| Hold lock field absent | Require physical PTT for local or phone hold; tap-lock remains disabled |
| Draft bounds unspecified | Starting bitrate 24 kbit/s, four-packet queue, 48 KiB task stack, requested MTU/interval and 200 ms pending deadline are engineering starting points, **unverified** on device |
| New START after a lost tail | Client disarms, resets decoder, requests snapshot and needs fresh release/press or OFF→REC; no automatic REC from a recovered snapshot |
| Contract feasibility | No blocking firmware contract problem found. Binary schema/codegen, phone trigger-lock timing and iOS interruption signalling remain open in the contract; SYS untouched |
| BlueZ MTU | **Yes**, public D-Bus AcquireNotify/AcquireWrite returns FD + actual MTU. Bleak 3.0.2 default public `mtu_size` reports 23; source evidence and method locations are in [client README](tools/ble_client/README.md). This client keeps StartNotify, prints public MTU and observed lower bound; firmware logs actual MTU. Phone writes' 20-byte budget never sizes Audio |
| Licences | `78/esp-opus` 1.0.5 metadata says MIT; actual libopus COPYING/source terms are BSD and retained. ES8311 registers Apache-2.0; M5 adaptation MIT; opuslib-next BSD; Bleak/dbus-fast MIT. No av/FFmpeg/GPL. Details in [licences](licences/README.md) |

Hardware-only: verify ES8311 left mic/gain, intelligible playback and restart
transients; OFF while held/REC/mid-fragment; accepted MTU/connection interval,
backpressure/recovery and END order on BlueZ/iOS; authenticated subscriptions,
bond/revoke/reconnect; encode mean/max, dropped frames, real heap/stack and CPU;
BLE/input/Orb responsiveness while encoding, display scanout, battery/power and
[REQ-51]/[REQ-53] source-quality/whisper benchmarks. Preserve owner-confirmed
controls/pairing/touch/Orb while checking these. No hardware compliance claimed.
