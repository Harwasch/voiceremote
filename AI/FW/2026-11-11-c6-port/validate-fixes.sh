#!/usr/bin/env bash
# Purpose: reproduce the C6 cross-review fix-round builds and host evidence.
# Inputs: installed IDF 5.5.6; offline mirror/cache variables supplied in shell.
# Verified: exits nonzero on any failure; device timing remains unverified.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export TMPDIR="$PWD/AI/scratch/tmp"
mkdir -p "$TMPDIR" AI/scratch/c6-fix
export PATH=$HOME/.local/share/uv/python/cpython-3.12.14-linux-x86_64-gnu/bin:$PATH
export IDF_TOOLS_PATH=$HOME/hw-tools/espressif
. "$HOME/hw-tools/esp-idf/export.sh"
export IDF_TOOLS_PATH=/tmp/voiceremote-espressif
: "${IDF_COMPONENT_STORAGE_URL:?Supply offline mirror in the shell}"
: "${IDF_COMPONENT_CACHE_PATH:?Supply writable component cache in the shell}"
export HEAVY_CPUS=4
export CMAKE_BUILD_PARALLEL_LEVEL=4
export CTEST_PARALLEL_LEVEL=1
for variant in m5 m5-hook c6 c6-hook; do
    args=(-DREMOTE_TIMING=ON)
    if [[ $variant == c6* ]]; then
        board=waveshare_c6_169
        args+=(-DREMOTE_BOARD="$board" -DIDF_TARGET=esp32c6)
    else
        board=m5stopwatch
        args+=(-DREMOTE_BOARD="$board" -DIDF_TARGET=esp32s3)
    fi
    if [[ $variant == *-hook ]]; then
        args+=(-DREMOTE_TEST_HOOK=ON -DREMOTE_RELEASE=OFF)
    else
        args+=(-DREMOTE_TEST_HOOK=OFF -DREMOTE_RELEASE=ON)
    fi
    heavy idf.py -C FW -B "FW/build-$variant" "${args[@]}" reconfigure > "AI/scratch/c6-fix/$variant-config.log" 2>&1
    heavy cmake --build "FW/build-$variant" -j 4 > "AI/scratch/c6-fix/$variant-build.log" 2>&1
    heavy idf.py -C FW -B "FW/build-$variant" -DREMOTE_BOARD="$board" build > "AI/scratch/c6-fix/$variant-finalize.log" 2>&1
    echo "$variant: three-step build passed"
done
heavy bash FW/tests/run.sh > AI/scratch/c6-fix/host-final.log 2>&1
echo 'FW host suite passed'
heavy bash FW/tools/ui_preview/run.sh > AI/scratch/c6-fix/preview-final.log 2>&1
echo 'FW native UI suite passed'
