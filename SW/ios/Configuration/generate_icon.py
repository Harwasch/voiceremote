"""Generate a placeholder waveform app icon using only the Python standard library.

The deterministic output is a build resource, not the final product artwork.
Apple single-size catalog: https://developer.apple.com/documentation/xcode/configuring-your-app-icon
"""
import json
from pathlib import Path
import struct
import zlib


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def generate():
    catalog = Path(__file__).parent / 'Assets.xcassets'
    icon = catalog / 'AppIcon.appiconset'
    icon.mkdir(parents=True, exist_ok=True)
    info = {'version': 1, 'author': 'voiceremote'}
    (catalog / 'Contents.json').write_text(json.dumps({'info': info}) + '\n')
    (icon / 'Contents.json').write_text(json.dumps({
        'images': [{'filename': 'AppIcon.png', 'idiom': 'universal',
                    'platform': 'ios', 'size': '1024x1024'}],
        'info': info,
    }) + '\n')
    # Opaque RGB: five simple vertical bars, no alpha channel or external artwork.
    size = 1024
    bars = [(272, 130), (392, 240), (512, 320), (632, 240), (752, 130)]
    rows = bytearray()
    for y in range(size):
        rows.append(0)  # PNG filter: none
        for x in range(size):
            waveform = any(abs(x - center) < 32 and abs(y - 512) < height for center, height in bars)
            rows.extend((105, 226, 206) if waveform else (17, 30, 49))
    header = struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
    (icon / 'AppIcon.png').write_bytes(png)


if __name__ == '__main__':
    generate()
