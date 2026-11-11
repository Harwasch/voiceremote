#!/usr/bin/env python3
"""Purpose: compare existing preview PNGs against the task's base commit.
Inputs: git base 4b756eb, host build objects/LVGL, synthetic fixtures.
Verified: exits nonzero for any changed baseline pixel; no hardware claims.
Run after FW/tests/run.sh, under heavy. Outputs stay in AI/scratch/c6-port.
"""
from pathlib import Path
import hashlib
import os
import shlex
import subprocess as sp

ROOT = Path(__file__).resolve().parents[3]
os.chdir(ROOT)
BASE = '4b756eb36f2f4ce36bd3f194b2d4e6a384f01c5e'
WORK = ROOT / 'AI/scratch/c6-port/reference'
WORK.mkdir(parents=True, exist_ok=True)
for name in ['ui.c', 'layout.h', 'ui_input.h']:
    (WORK / name).write_bytes(sp.check_output(['git', 'show', f'{BASE}:FW/app/{name}']))
(WORK / 'main.c').write_bytes(sp.check_output(['git', 'show', f'{BASE}:FW/tools/ui_preview/main.c']))
preview = ROOT / 'FW/tools/ui_preview'
lvgl = ROOT / 'FW/managed_components/lvgl__lvgl'
build = ROOT / 'FW/build-host/ui-preview'
flags = ['-O2', '-Wall', '-Wextra', '-Werror', '-UNDEBUG', '-DUI_PREVIEW=1', '-DVR_TIMING=1',
         '-DLV_KCONFIG_IGNORE', '-DLV_LVGL_H_INCLUDE_SIMPLE', f'-DLV_CONF_PATH="{preview}/lv_conf.h"']
for inc in [WORK, preview, preview/'stubs', ROOT/'FW/app', lvgl, build/'lvgl']:
    flags += ['-I', str(inc)]
for name in ['main', 'ui']:
    sp.run(['cc', *flags, '-c', str(WORK/f'{name}.c'), '-o', str(WORK/f'{name}.o')], check=True)
link = shlex.split((build/'CMakeFiles/ui_preview.dir/link.txt').read_text())
objects = [str(build/p) for p in link if p.endswith('.o') and not p.endswith('/main.c.o') and not p.endswith('/ui.c.o')]
sp.run(['c++', str(WORK/'main.o'), str(WORK/'ui.o'), *objects,
        str(build/'lvgl/lib/liblvgl.a'), '-lm', '-o', str(WORK/'baseline')], check=True)
states = 'off ptt-armed ptt-listening-transcribe rec-listening-ai auto-target named-target long-name error-text no-link pairing-number forget-confirm rectangular offline-recording offline-waiting storage-full recordings-waiting syncing'.split()
for state in states:
    old, new = WORK/f'{state}-base.png', WORK/f'{state}-new.png'
    sp.run([str(WORK/'baseline'), state, str(old)], check=True, stdout=sp.DEVNULL)
    sp.run([str(build/'ui_preview'), state, str(new)], check=True, stdout=sp.DEVNULL)
    assert old.read_bytes() == new.read_bytes(), state
    print(state, hashlib.sha256(new.read_bytes()).hexdigest())
print(f'PASS: {len(states)} existing fixtures byte-identical to {BASE}')
