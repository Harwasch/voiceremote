#!/usr/bin/env python3
"""Purpose: verify built versions/capability metadata and report type allocation sizes.
Inputs: both ELF files, generated configs, IDF pyelftools. Verified: assertions below.
No board/serial/Bluetooth IO. Run in the exported IDF Python environment.
"""
from pathlib import Path
import struct
from elftools.elf.elffile import ELFFile

root = Path(__file__).resolve().parents[3]
for board, expected_id, expected_caps in [('m5', 1, 0xbf), ('c6', 2, 0)]:
    build = root / f'FW/build-{board}'
    with (build / 'voice_remote.elf').open('rb') as file:
        elf = ELFFile(file)
        section = elf.get_section_by_name('.flash.appdesc')
        version = section.data()[16:48].split(b'\0')[0].decode()
        assert version == '0.3.0', (board, version)
        infos = [s for s in elf.get_section_by_name('.symtab').iter_symbols() if s.name == 'info' and s['st_size'] == 12]
        assert len(infos) == 1
        symbol = infos[0]
        section = elf.get_section(symbol['st_shndx'])
        at = symbol['st_value'] - section['sh_addr']
        board_id, width, height, caps = struct.unpack_from('<4H', section.data(), at)
        assert (board_id, caps) == (expected_id, expected_caps)
        sizes = {}
        dwarf = elf.get_dwarf_info()
        for cu in dwarf.iter_CUs():
            for die in cu.iter_DIEs():
                name = die.attributes.get('DW_AT_name')
                if name and name.value in (b'vr_store_t', b'job_t') and 'DW_AT_type' in die.attributes:
                    target = die.get_DIE_from_attribute('DW_AT_type')
                    size = target.attributes.get('DW_AT_byte_size')
                    if size: sizes[name.value.decode()] = size.value
        print(f'{board}: ELF firmware={version} board={board_id} caps=0x{caps:02x} offline={bool(caps & 128)} type_bytes={sizes}')
    config = (build / 'sdkconfig').read_text()
    assert 'CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ=160' in config
    if board == 'm5':
        assert 'CONFIG_PARTITION_TABLE_CUSTOM=y' in config
        assert 'CONFIG_I2S_ISR_IRAM_SAFE=y' in config
        assert 'CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y' in config
    else:
        assert 'CONFIG_PARTITION_TABLE_SINGLE_APP_LARGE=y' in config
        assert 'CONFIG_ESPTOOLPY_FLASHSIZE_4MB=y' in config
