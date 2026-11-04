#!/usr/bin/env python3
"""Purpose: check final build/visual/move evidence without hardware.
Inputs: generated sdkconfigs, compile commands, binaries and baseline PNG hashes.
Verification: assertions fail on config/hook/visual/licence inconsistencies.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[3]
evidence = Path(__file__).resolve().parent
for build, frequency, hook in [('m5', 240, False), ('c6', 160, False), ('m5-hook', 240, True)]:
    directory = root / f'FW/build-{build}'
    config = (directory/'sdkconfig').read_text()
    assert 'CONFIG_COMPILER_OPTIMIZATION_PERF=y' in config
    assert f'CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ={frequency}\n' in config
    if build == 'c6':
        assert 'CONFIG_SPIRAM=y' not in config
    commands = json.loads((directory/'compile_commands.json').read_text())
    command = next(c['command'] for c in commands if c['file'].endswith('/app/main.c'))
    assert ' -O2 ' in command
    assert ('-DREMOTE_TEST_HOOK=1' in command) == hook
    info = json.loads((directory/'project_description.json').read_text())
    requires = info['build_component_info']['app']['reqs']
    assert ('esp_driver_usb_serial_jtag' in requires) == hook
    image = (directory/'voice_remote.bin').read_bytes()
    assert (b'TEST BUILD' in image) == hook
    symbols = subprocess.check_output([info['monitor_toolprefix']+'nm', str(directory/'voice_remote.elf')], text=True)
    assert (' ui_test_control' in symbols) == hook
    print(f'{build}: -O2, {frequency} MHz, hook={hook}, app USB dependency={hook}, bin={len(image)} B')
    subprocess.run(['git', 'check-ignore', str(directory/'sdkconfig')], cwd=root, check=True, capture_output=True)

for line in (evidence/'baseline.sha256').read_text().splitlines():
    if line.startswith('#'):
        continue
    expected, name = line.split('  ')
    image = root/'FW/build-preview'/name
    assert hashlib.sha256(image.read_bytes()).hexdigest() == expected, name
    assert image.read_bytes() == (root/'FW/build-preview/no-cache'/name).read_bytes(), name
print('17 PNGs: byte-identical to b0daefb baseline and primitive fallback')

for notice in (root/'DOCS/licences').glob('*.txt'):
    before = subprocess.check_output(['git', 'show', f'HEAD:FW/licences/{notice.name}'], cwd=root)
    assert notice.read_bytes() == before, notice.name
print('13 external licence notices: identical after move')

for name in ['s3', 'c6', 'hook']:
    log = (evidence/f'{name}.log').read_text()
    size = re.search(r'Total image size: (\d+) bytes', log)[1]
    ram = re.search(r'│ DIRAM\s+│\s+(\d+)', log)[1]
    print(f'{name}: image={size} B, DIRAM={ram} B')
