#!/usr/bin/env python3
"""Purpose: capture linked sizes/types and calculate the C6 RAM budget.
Inputs: final size logs + C6 ELF; supplied C6 bench is separate evidence.
Verified: linked sizes/arithmetic only, runtime free heap and timing unverified.
Run after validate.sh with IDF environment active. No device access.
"""
from pathlib import Path
import re
import subprocess as sp

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
LOG = ROOT / 'AI/scratch/c6-port'
rows = []
values = {}
for name in ['stub', 'c6', 'm5', 'm5-hook']:
    raw = (LOG/f'{name}-size.log').read_text()
    image = int(re.search(r'Total image size: (\d+)', raw)[1])
    match = re.search(r'│ DIRAM\s+│\s+(\d+)\s+│[^│]+│\s+(\d+)', raw)
    used, remaining = map(int, match.groups())
    values[name] = (image, used, remaining)
    binary = (ROOT/f'FW/build-{name}/voice_remote.bin')
    rows.append(f'| {name} | {image:,} | {binary.stat().st_size if binary.exists() else "baseline only"} | {used:,} | {remaining:,} |')
commands = ['p sizeof(struct OpusEncoder)', 'p sizeof(vr_store_t)', 'p sizeof(job_t)',
            'disassemble opus_encoder_get_size', 'disassemble silk_Get_Encoder_Size', 'disassemble celt_encoder_get_size']
args = ['riscv32-esp-elf-gdb', '-batch', '-nx', str(ROOT/'FW/build-c6/voice_remote.elf')]
for command in commands:
    args += ['-ex', command]
proof = sp.check_output(args, text=True, stderr=sp.STDOUT)
(HERE/'ram-evidence.txt').write_text('Purpose: linked C6 RAM/type/encoder evidence.\nInputs: final voice_remote.elf; GDB file inspection only.\nVerified: linked values; no runtime heap measurement.\n\n'+proof)
assert '$1 = 2208' in proof and '$2 = 49232' in proof and '$3 = 544' in proof
# Linked silk size is 0x43c8. Linked CELT calculation is
# (1024*channels + 61 + channels*overlap + 4*channels*nbEBands)*4.
# The bundled static 48k mode used by get_size has overlap=120, nbEBands=21.
assert '0x43c8' in proof and 'a4,61' in proof
encoder = 2208 + 0x43c8 + (1024 + 61 + 120 + 4*21)*4
known = {'Store': 49232, '18 queue jobs': 18*544, 'Opus state': encoder,
         'Opus stack': 32768, 'Writer stack': 6144, 'Renderer stack': 8192,
         'I2S DMA payload': 4*320*2*2, 'LCD strip': 240*8*2}
ble_budget = 8192 + 4096 + 24*(128+320)
image_delta = values['c6'][0]-values['stub'][0]
ram_delta = values['c6'][1]-values['stub'][1]
text = '''> **Purpose:** final linked size/RAM arithmetic. **Inputs:** IDF size logs, ELF/GDB, configured allocation bounds. **Verified:** build sizes and arithmetic; runtime free heap **TBC**.

```mermaid
flowchart LR
    ELF[Linked C6 ELF] --> Static[Static DIRAM usage]
    Alloc[Known dynamic bounds] --> Budget[Residual before uncounted overhead]
    Static --> Budget
    Budget --> Hardware[Boot heap / stack / audio test still required]
```

| Build | IDF image bytes | Padded binary bytes | DIRAM used | DIRAM remaining |
|---|---:|---:|---:|---:|
'''+ '\n'.join(rows)+f'''

C6 delta versus build-only stub: **+{image_delta:,} image bytes**, **+{ram_delta:,} static DIRAM bytes**.
The reference 452,112-byte linker region excludes reserved memory; 512 KiB chip SRAM
is not a free-heap figure. Linker remaining is not runtime free heap.

| Known dynamic allocation | Bytes |
|---|---:|
'''+ '\n'.join(f'| {k} | {v:,} |' for k,v in known.items())+f'''
| Known subtotal | {sum(known.values()):,} |
| BLE host/controller stacks + configured msys payload budget | {ble_budget:,} |
| Residual before other IDF/controller/driver/heap/task overhead | {values['c6'][2]-sum(known.values())-ble_budget:,} |

This residual is an **estimate / upper budget, TBC**, not measured free heap.
LVGL's 48 KiB built-in pool is already included in static BSS; the 2500/7056-byte
A8 glyph lives inside it, not in an extra full artwork cache. Driver descriptors,
queue/allocator overhead, controller allocations, other system task stacks and
fragmentation reduce the residual. Boot logs actual free/minimum internal heap;
production audio logs allocation size, free heap and stack watermark when the
audio tag is enabled. The 32 KiB stack follows the owner's ~22 KiB synthetic
measurement, leaving ~10 KiB nominal margin (production maximum **TBC**).

Opus mono allocation is {encoder:,} bytes from the linked size functions:
2208-byte outer state + 17352-byte SILK + 5156-byte CELT, aligned to four bytes.
See `ram-evidence.txt` and `measure.py`; the CELT static 48k mode used by get_size
has overlap 120 and 21 bands (`celt/static_modes_fixed.h:1519–1523`). This is
allocation sizing, not an encode throughput measurement.

Bit 7 remains enabled on the measured 16 MiB C6: RAM arithmetic leaves room for
the shared store, bounded queue and production encoder with BLE. It clears before
offline allocation/registration for missing or physically out-of-range storage.
Physical heap/stack sufficiency and flash-cache stalls remain **unverified**.

Raw logs are ignored under `AI/scratch/c6-port/`; `validate.sh` and
`verify_reference.py` reproduce the checks. No new dependency graph was needed.
'''
(HERE/'measurements.md').write_text(text)
print(text)
