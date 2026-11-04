# Touch and offline Orb evidence

Purpose: record failing-first touch regression and native UI verification.
Inputs: production ui_input.h/ui.c, board touch API, synthetic host/native fixtures.
Verified: host regression failed before fix and passed afterward; 17 native states
pass. Hardware/I2C/panel timing remains unverified.

| Command / stage | Observed result |
|---|---|
| `heavy bash FW/tests/run.sh`, failing test before fix | Exit 8; remote_logic aborted at then-test.c:307: `vr_ui_touch_sample(&p,false,false,VR_HIT_REC,105)==VR_HIT_NONE`; 3/4 suites pass |
| Same command after 100 ms hold/cancel fix | Exit 0; 4/4 suites pass |
| `TMPDIR="$PWD/AI/scratch/offline-ui-tmp" heavy bash FW/tools/ui_preview/run.sh` | Exit 0; 17 states rendered; offline listening/reconnect/full/waiting/OFF/sync partial redraw checks and touch glitch checks pass |
| Baseline PNG SHA256 comparison | All twelve unchanged; hashes in `ui-baseline-sha256.json` |

Native destination update remains 44,270 pixels, y=356..450. Listening pulse is
359,120 pixels/1 s within (99,99)..(366,366). Native numbers measure renderer
work only, not device time. Inspected offline-waiting and storage-full PNGs.

A /tmp compiler write initially failed with disk quota exceeded. Workspace
TMPDIR resolves compiler temporaries; no unrelated /tmp files were deleted.
