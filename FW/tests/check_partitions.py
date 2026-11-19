#!/usr/bin/env python3
"""Compare generated board partition tables with IDF's previous single_app_large.
Inputs: local IDF CSV and generated binaries. Verified by host runner after builds.
"""
import csv
import os
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
IDF = Path(os.environ.get('IDF_PATH', str(Path.home() / 'hw-tools/esp-idf')))

def binary(path):
    entries = {}
    for at in range(0, len(data := path.read_bytes()), 32):
        row = data[at:at + 32]
        if len(row) < 32 or row[:2] != b'\xaaP':
            continue
        _, typ, sub, off, size, label, _ = struct.unpack('<HBBII16sI', row)
        entries[label.rstrip(b'\0').decode()] = (typ, sub, off, size)
    return entries

def number(value):
    value = value.strip()
    return int(value[:-1], 0) * 1024 if value.endswith('K') else int(value, 0)

def main():
    old = {}
    previous_end = 0x9000
    for row in csv.reader((IDF / 'components/partition_table/partitions_singleapp_large.csv').read_text().splitlines()):
        if not row or row[0].lstrip().startswith('#'): continue
        name, _, _, off, size, *_ = (s.strip() for s in row)
        alignment = 0x10000 if name == 'factory' else 0x1000
        offset = number(off) if off else (previous_end + alignment - 1) // alignment * alignment
        old[name] = (offset, number(size))
        previous_end = offset + number(size)
    assert old['nvs'] == (0x9000, 0x6000), old
    for board, flash in [('m5', 16 * 1024**2), ('c6', 16 * 1024**2)]:
        path = ROOT / f'FW/build-{board}/partition_table/partition-table.bin'
        if not path.exists():
            raise RuntimeError(f'build {board} first: {path}')
        table = binary(path)
        # Historical generated baseline: NVS type/subtype, offset and size.
        assert table['nvs'] == (1, 2, 0x9000, 0x6000), (board, table['nvs'])
        assert table['nvs'][2:] == old['nvs'], (board, table['nvs'], old['nvs'])
        assert table['phy_init'][2:] == old['phy_init']
        expected_app = old['factory'] if board == 'm5' else (0x10000, 0x1c0000)
        assert table['factory'] == (0, 0, *expected_app), (board, table['factory'])
        assert table['factory'][2] % 0x10000 == 0
        if board == 'c6':
            # Headroom means unused fraction of the app partition (stricter than
            # (partition-image)/image). Check hook too whenever its image exists.
            for variant in ('c6', 'c6-hook'):
                image = ROOT / f'FW/build-{variant}/voice_remote.bin'
                if image.exists():
                    used = image.stat().st_size
                    size = table['factory'][3]
                    assert used * 5 <= size * 4, (variant, used, size)
                    print(f'{variant}: image={used} app={size} headroom={(size-used)/size:.2%}')
                else:
                    # 1,389,696-byte reviewed image needs at least 1,737,120 B.
                    assert table['factory'][3] >= 1737120
        assert all(off + size <= flash for _, _, off, size in table.values())
        offline = (0x187000, 0xe79000) if board == 'm5' else (0x1d0000, 0xe30000)
        assert table['offline'] == (1, 0x40, *offline), table
        entries = sorted((off, size) for _, _, off, size in table.values())
        assert all(off % 0x1000 == 0 and size % 0x1000 == 0 for off, size in entries)
        assert all(off + size <= next_off for (off, size), (next_off, _) in zip(entries, entries[1:]))
        assert max(off + size for _, _, off, size in table.values()) == flash
        print(f'{board}: generated NVS offset=0x9000 size=0x6000 matches previous table; fits {flash} bytes')
        for name, (_, _, off, size) in table.items(): print(f'  {name}: 0x{off:x} + 0x{size:x}')
if __name__ == '__main__': main()
