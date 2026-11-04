#!/usr/bin/env bash
# Purpose: regenerate the shipped Lexend SemiBold subset (OFL).
# Inputs: lv_font_conv 1.5.3 and static Lexend SemiBold TTF (wght=600).
# Verified by firmware and native preview builds; see README.md for exact command.
set -euo pipefail
conv=$1
font=$2
cd "$(dirname "$0")"
for size in 24 30 42; do
    node "$conv" --bpp 4 --size "$size" --no-compress --format lvgl --font "$font" -r 0x20-0x7e -o "lexend_${size}.c" --lv-include lvgl.h
 done
node "$conv" --bpp 4 --size 84 --no-compress --format lvgl --font "$font" -r 0x30-0x39 -o lexend_84.c --lv-include lvgl.h
# Keep generated output independent of machine-specific input paths.
python3 - <<'NORMALISE'
from pathlib import Path
for p in Path('.').glob('lexend_*.c'):
    s=p.read_text()
    lines=s.splitlines()
    lines=[(' * Regenerate: see README.md and generate.sh (lv_font_conv 1.5.3).'
            if line.startswith(' * Opts:') else line) for line in lines]
    p.write_text('\n'.join(lines)+'\n')
NORMALISE
