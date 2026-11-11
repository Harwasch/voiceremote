#!/usr/bin/env bash
# Purpose: reproduce final builds and evidence without hardware access.
# Inputs: installed IDF 5.5.6; mirror/cache variables supplied by the operator.
# Verification: exits on any unexpected failure; hardware remains unverified.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PATH=$HOME/.local/share/uv/python/cpython-3.12.14-linux-x86_64-gnu/bin:$PATH
export IDF_TOOLS_PATH=$HOME/hw-tools/espressif
. "$HOME/hw-tools/esp-idf/export.sh"
export IDF_TOOLS_PATH=/tmp/voiceremote-espressif
: "${IDF_COMPONENT_STORAGE_URL:?Supply offline mirror in the shell}"
: "${IDF_COMPONENT_CACHE_PATH:?Supply writable component cache in the shell}"
mkdir -p AI/scratch/c6-port/tmp
export TMPDIR="$PWD/AI/scratch/c6-port/tmp"
for variant in m5 m5-hook c6; do
    args=(-DREMOTE_TIMING=ON -DREMOTE_TEST_HOOK=OFF -DREMOTE_RELEASE=ON)
    if [[ $variant == c6 ]]; then
        args+=(-DREMOTE_BOARD=waveshare_c6_169 -DIDF_TARGET=esp32c6)
    else
        args+=(-DREMOTE_BOARD=m5stopwatch -DIDF_TARGET=esp32s3)
    fi
    if [[ $variant == m5-hook ]]; then
        args+=(-DREMOTE_TEST_HOOK=ON -DREMOTE_RELEASE=OFF)
    fi
    heavy idf.py -C FW -B "FW/build-$variant" "${args[@]}" reconfigure > "AI/scratch/c6-port/$variant-config.log" 2>&1
    heavy cmake --build "FW/build-$variant" -j 4 > "AI/scratch/c6-port/$variant-build.log" 2>&1
    heavy idf.py -C FW -B "FW/build-$variant" build > "AI/scratch/c6-port/$variant-finalize.log" 2>&1
    heavy idf.py -C FW -B "FW/build-$variant" size > "AI/scratch/c6-port/$variant-size.log" 2>&1
done
if heavy cmake -S FW -B FW/build-hook-release-reject -DREMOTE_TEST_HOOK=ON -DREMOTE_RELEASE=ON > AI/scratch/c6-port/hook-reject.log 2>&1; then
    echo 'ERROR: release accepted the test hook' >&2; exit 1
fi
rg -q 'REMOTE_TEST_HOOK is forbidden' AI/scratch/c6-port/hook-reject.log
heavy bash FW/tests/run.sh > AI/scratch/c6-port/host-final.log 2>&1
heavy bash FW/tools/ui_preview/run.sh > AI/scratch/c6-port/preview-final.log 2>&1
heavy python3 AI/FW/2026-11-11-c6-port/verify_reference.py > AI/scratch/c6-port/reference-final.log 2>&1
