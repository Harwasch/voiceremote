# Host verification

```mermaid
flowchart LR
    Contract[remote-ble.md hex examples] --> C[test.c]
    C --> Logic[protocol.c + state.c + layout.h]
    Contract --> Python[test_wire.py + test_audio.py]
    Audio[test_audio.c: fake encoder] --> Framer[production audio.c]
    Framer -->|binary length-prefixed frames| Python
    Runtime[test_offline_runtime.c + test_audio_runtime.c] --> Lifecycle[production runtime / queue / codec lifecycle]
    Lifecycle --> Stubs[offline_stubs: synthetic ESP + FreeRTOS]
    Run[run.sh] --> CTest[CMake + ctest]
    CTest --> C & Python & Runtime
```

| File | Purpose | Status |
|---|---|---|
| `run.sh` | Single root-runnable host command | ✅ Reproducible |
| `CMakeLists.txt` | Plain native C, warnings as errors, assertions enabled; Python ≥3.12 | ✅ No IDF/board needed |
| `test.c` | I, E0–E5, P, A0–A2 round trips; malformed UTF-8/flags/enums/lengths, all split offsets, overflow, atomicity, transaction/input wrap, arm/OFF, debounce, scaled Orb sectors/disc/target/modals/dead zones, live/offline listening truth table, failed-touch-read hold/timeout/rearm/wrap, UTF-8 fallback, immediate preview/rollback and controls changing during a display wait | ✅ Host tested |
| `test_offline_store.c` | Fake-flash power loss at every script write boundary, torn writes/erases/final frame, prefix recovery, full, resume, metadata/CRC, delete retry, ID/boot persistence, corruption and journal rotation | ✅ Host tested |
| `test_offline_capture.c` | Fresh triggers, disconnect/reconnect, stored mode, OFF, owner/incompatibility/pause gates | ✅ Host tested |
| `check_partitions.py` | Generated StopWatch/C6 tables against original NVS offset/size and flash bounds | ✅ Build outputs required |
| `../tools/ble_client/test_offline.py` | Contract offline hex/fragments, resume/integrity, durable copy and clock behavior | ✅ Host tested |
| `test_config.py` | Rejects hook for explicit release and GitHub/GitLab firmware-tag signals before IDF setup | ✅ Host tested |
| `test_hook.c` | All serial commands, unknown input and held/released PTT decoder | ✅ Host tested |
| `../tools/hil/test_run_offline.py` | Entire unattended procedure using fake serial/BLE, durable fetch interruption/resume, failure and PTY serial collector | ✅ Host tested |
| `test_audio.c` | Production queue/framer with fake encoder: MTU 23/247, START/END/LAST, MTU changes, OFF discard, arm/hold gate, overflow and sequence/segment exhaustion; binary fixture mode | ✅ Host tested |
| `test_audio_runtime.c` | Production audio lifecycle: codec generation survives BLE reconnect/reset during local recording; live reset invalidates generation; OFF immediately stops mic/suspends worker and discards in-flight encoder output | ✅ Host tested |
| `test_offline_runtime.c`, `offline_stubs/` | Production writer and sync transport with synthetic NOR and bounded FIFO: queued/in-flight begin OFF, volatile discard, queue/flash full, write failure, clock/progress, contract result layouts, resume/deletion after reboot, enrollment guard, C6 capability stub and live preemption; asserts storage IO never holds the app mutex | ✅ Host tested |
| `../tools/ble_client/test_audio.py` | C-to-Python framing at MTU 23/64/247/517, loss/conflicts/duplicates/watchdog, reconnect/ack/trigger policy, WAV format and real libopus decode | ✅ Host tested |
| `../tools/ble_client/test_wire.py` | Independent synthetic Python wire fixtures | ✅ Host tested |

Run from repository root, exactly:

```sh
heavy bash FW/tests/run.sh
```

[REQ-8], [REQ-18], [REQ-49–53] traceability only: these tests prove pure logic,
not GPIO timing, BLE stack behavior, physical display visibility or safety.
The test runner uses the client's locked `.venv` when available. Prepare it with
`uv sync --project FW/tools/ble_client` (offline environment in its README) to run
the real Opus/WAV case; otherwise that one codec test skips. Pure C and framing
round trips need no libopus headers. Fixtures are synthetic bytes/silence only.
They do not establish on-device encoding capacity or acoustic quality.

The pure gesture tests assert preview changes without protocol state changes,
release acceptance, cancellation without retargeting, and direct PTT→OFF. The
touch fault regression first failed by accepting REC on an I2C error; the fix
passes recovery, 100 ms cancellation, observed-up rearming and clock wrap. The
existing arm rule also rejects a stale control epoch after final-fragment parsing.

The writer regression first failed when OFF discarded an unopened queued record,
then an unnecessary finalize blocked live capture. Both queued and in-flight begin
cases now pass. Runtime tests execute the production source, capture policy and
store with fake queues/NOR; audio lifecycle tests replace the codec and microphone.
They establish scheduling decisions and generation checks, not flash-stall latency.

The actual LVGL interaction/display-barrier and pulse-bound checks run with
`heavy bash FW/tools/ui_preview/run.sh`; see [the preview](../tools/ui_preview/README.md).

The store resume test counts fake-flash reads: fetching the final frame of a
300-frame/two-sector record needs 96 reads, before and after remount, and never
rereads the first sector. The 16 KiB index changes RAM only, not flash format.

The root test command now also builds/runs the **real LVGL renderer** (managed
LVGL must exist). It models 175 ms redraw and a 450 ms completion racing wait
expiry; matching completed DMA succeeds. Missing/failed/modal draws fail.
Hook and PSRAM-free variants run too. Audio regressions cover one completely
unsent queued frame at OFF and C→Python clean END, retaining partial-frame loss.
