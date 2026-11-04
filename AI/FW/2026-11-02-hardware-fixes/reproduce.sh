#!/usr/bin/env bash
# Purpose: reproduce final host/UI/build/release checks without hardware.
# Inputs: b0daefb + working changes, supplied IDF 5.5.6 and offline caches.
# Verification: set -e; every final check and build must succeed (release must fail).
set -euo pipefail
cd "$(dirname "$0")/../../.."
export PATH=$HOME/.local/share/uv/python/cpython-3.12.14-linux-x86_64-gnu/bin:$PATH
export IDF_TOOLS_PATH=$HOME/hw-tools/espressif
. ~/hw-tools/esp-idf/export.sh
export IDF_TOOLS_PATH=/tmp/voiceremote-espressif
# Offline mirror/cache environment is supplied by the caller, never stored here.
export TMPDIR=$PWD/AI/scratch/stopwatch-final-tmp
mkdir -p "$TMPDIR"
evidence=AI/FW/2026-11-02-hardware-fixes
for log in host preview s3 c6 hook release-reject verification; do
    printf '# Purpose: final %s verification. Inputs: working firmware + pinned offline toolchain.\n# Verification: command status checked by reproduce.sh; hardware unverified.\n' "$log" > "$evidence/$log.log"
done
heavy bash FW/tests/run.sh >> "$evidence/host.log" 2>&1
heavy bash FW/tools/ui_preview/run.sh >> "$evidence/preview.log" 2>&1
# Regenerate each generated sdkconfig so defaults really take effect.
for board_build in m5 c6 m5-hook; do
    if [[ -f FW/build-$board_build/sdkconfig ]]; then
        mv "FW/build-$board_build/sdkconfig" "$TMPDIR/sdkconfig-$board_build-before"
    fi
done
heavy idf.py -C FW -B FW/build-m5 -DIDF_TARGET=esp32s3 -DREMOTE_TIMING=ON -DREMOTE_TEST_HOOK=OFF -DREMOTE_RELEASE=ON reconfigure >> "$evidence/s3.log" 2>&1
heavy cmake --build FW/build-m5 -j 4 >> "$evidence/s3.log" 2>&1
heavy idf.py -C FW -B FW/build-m5 build >> "$evidence/s3.log" 2>&1
heavy idf.py -C FW -B FW/build-m5 size >> "$evidence/s3.log" 2>&1
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 -DIDF_TARGET=esp32c6 -DREMOTE_TIMING=ON -DREMOTE_TEST_HOOK=OFF -DREMOTE_RELEASE=ON reconfigure >> "$evidence/c6.log" 2>&1
heavy cmake --build FW/build-c6 -j 4 >> "$evidence/c6.log" 2>&1
heavy idf.py -C FW -B FW/build-c6 -DREMOTE_BOARD=waveshare_c6_169 build >> "$evidence/c6.log" 2>&1
heavy idf.py -C FW -B FW/build-c6 size >> "$evidence/c6.log" 2>&1
heavy idf.py -C FW -B FW/build-m5-hook -DIDF_TARGET=esp32s3 -DREMOTE_TIMING=ON -DREMOTE_TEST_HOOK=ON -DREMOTE_RELEASE=OFF reconfigure >> "$evidence/hook.log" 2>&1
heavy cmake --build FW/build-m5-hook -j 4 >> "$evidence/hook.log" 2>&1
heavy idf.py -C FW -B FW/build-m5-hook build >> "$evidence/hook.log" 2>&1
heavy idf.py -C FW -B FW/build-m5-hook size >> "$evidence/hook.log" 2>&1
if heavy cmake -S FW -B FW/build-hook-release-reject -DREMOTE_TEST_HOOK=ON -DREMOTE_RELEASE=ON >> "$evidence/release-reject.log" 2>&1; then
    echo "FAIL: release accepted the hook" >&2
    exit 1
fi
rg -q 'REMOTE_TEST_HOOK is forbidden in release builds' "$evidence/release-reject.log"
heavy python3 "$evidence/verify.py" >> "$evidence/verification.log"
rm -f "$TMPDIR"/sdkconfig-*-before "$TMPDIR"/kconfgen_tmp*.old
rmdir "$TMPDIR"
echo "PASS: host / previews / S3 / C6 / hook / release rejection / artifacts"
