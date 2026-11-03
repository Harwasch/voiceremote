#!/usr/bin/env bash
# Purpose: reproduce all baseline and offline PNGs with the real firmware UI.
# Inputs: LVGL managed source + bundled fonts + synthetic fixtures. Verified: exits on failure.
set -euo pipefail
cd "$(dirname "$0")/../../.."
cmake -S FW/tools/ui_preview -B FW/build-preview/native
cmake --build FW/build-preview/native -j 4
FW/build-preview/native/ui_preview --check
VR_UI_NO_CACHE=1 FW/build-preview/native/ui_preview --check
FW/build-preview/native/ui_preview_hook --check
FW/build-preview/native/ui_preview --timing
VR_UI_NO_CACHE=1 FW/build-preview/native/ui_preview --timing
mkdir -p FW/build-preview/no-cache
for state in off ptt-armed ptt-listening-transcribe rec-listening-ai auto-target named-target long-name error-text no-link pairing-number forget-confirm rectangular offline-recording offline-waiting storage-full recordings-waiting syncing; do
    FW/build-preview/native/ui_preview "$state" "FW/build-preview/$state.png"
    VR_UI_NO_CACHE=1 FW/build-preview/native/ui_preview "$state" "FW/build-preview/no-cache/$state.png"
    cmp "FW/build-preview/$state.png" "FW/build-preview/no-cache/$state.png"
done
