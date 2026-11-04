#!/usr/bin/env bash
# Purpose: repeat the requested host/preview and S3/C6 build/size verification.
# Inputs: checked-in FW, local IDF 5.5.6 and prepared offline tool/component caches.
# Verified: see final-*.log; never opens serial/Bluetooth or flashes hardware.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PATH=$HOME/.local/share/uv/python/cpython-3.12.14-linux-x86_64-gnu/bin:$PATH
export IDF_TOOLS_PATH=$HOME/hw-tools/espressif
. ~/hw-tools/esp-idf/export.sh
export IDF_TOOLS_PATH=/tmp/voiceremote-espressif
# Caller supplies optional shell-only mirror/cache variables; no mirror location here.
export TMPDIR=$PWD/AI/scratch/offline-build-tmp
mkdir -p "$TMPDIR"
log_dir=AI/FW/2026-11-02-offline-sync
heavy bash FW/tests/run.sh >"$log_dir/final-host.log" 2>&1
heavy bash FW/tools/ui_preview/run.sh >"$log_dir/final-preview.log" 2>&1
python "$log_dir/check-ui-baseline.py" >"$log_dir/final-ui-baseline.log"
heavy idf.py -C FW -B FW/build-m5 -DIDF_TARGET=esp32s3 -DREMOTE_TIMING=ON reconfigure >"$log_dir/final-s3-reconfigure.log" 2>&1
heavy cmake --build FW/build-m5 -j 4 >"$log_dir/final-s3-build.log" 2>&1
heavy idf.py -C FW -B FW/build-m5 build >"$log_dir/final-s3-idf.log" 2>&1
heavy idf.py -C FW -B FW/build-m5 size >"$log_dir/final-s3-size.log" 2>&1
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 -DIDF_TARGET=esp32c6 -DREMOTE_TIMING=ON reconfigure >"$log_dir/final-c6-reconfigure.log" 2>&1
heavy cmake --build FW/build-c6 -j 4 >"$log_dir/final-c6-build.log" 2>&1
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 build >"$log_dir/final-c6-idf.log" 2>&1
heavy idf.py -C FW -B FW/build-c6 size >"$log_dir/final-c6-size.log" 2>&1
python FW/tests/check_partitions.py >"$log_dir/final-partitions.log"
python "$log_dir/check-builds.py" >"$log_dir/final-build-metadata.log"
printf 'Host, preview, baseline hashes, S3/C6 build/size and partitions passed.\n'
