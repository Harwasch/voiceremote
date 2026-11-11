#!/usr/bin/env bash
# Purpose: reproduce C6-only display-offset follow-up validation.
# Inputs: installed IDF 5.5.6; mirror/cache variables supplied by the operator.
# Verified: successful build/size logs; physical panel remains unverified.
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
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 -DIDF_TARGET=esp32c6 -DREMOTE_TIMING=ON -DREMOTE_TEST_HOOK=OFF -DREMOTE_RELEASE=ON reconfigure > AI/scratch/c6-port/c6-config.log 2>&1
heavy cmake --build FW/build-c6 -j 4 > AI/scratch/c6-port/c6-build.log 2>&1
heavy idf.py -C FW -B FW/build-c6 build > AI/scratch/c6-port/c6-finalize.log 2>&1
heavy idf.py -C FW -B FW/build-c6 size > AI/scratch/c6-port/c6-size.log 2>&1
