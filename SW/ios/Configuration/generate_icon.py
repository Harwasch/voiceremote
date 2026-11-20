"""Generate the Voice Remote microphone icon as light/dark/tinted PNGs.

Purpose: reproducible product artwork; inputs: original analytic microphone paths.
Verified: PNG/catalog structure locally; rendered Home Screen appearance unverified.
Uses native asset-catalog variants; Icon Composer compilation requires Apple tools.
https://developer.apple.com/documentation/xcode/configuring-your-app-icon
"""
import json
import math
from pathlib import Path
import struct
import zlib


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def rounded_distance(x, y, cx, cy, half_width, half_height, radius):
    dx, dy = abs(x - cx) - half_width + radius, abs(y - cy) - half_height + radius
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius


def render(variant, size=1024):
    palettes = {
        'light': ((38, 114, 232), (24, 52, 163), (255, 255, 255)),
        'dark': ((18, 30, 60), (7, 12, 29), (166, 213, 255)),
        'tinted': ((40, 40, 40), (12, 12, 12), (255, 255, 255)),
    }
    top, bottom, ink = palettes[variant]
    rows = bytearray()
    scale = 1024 / size
    for y in range(size):
        rows.append(0)
        py = (y + 0.5) * scale
        background = [a + (b - a) * y / max(size - 1, 1) for a, b in zip(top, bottom)]
        for x in range(size):
            px = (x + 0.5) * scale
            body = rounded_distance(px, py, 512, 370, 88, 164, 88)
            # A U-shaped cradle with tangential straight sides, stem, and base.
            if py >= 452:
                cradle = abs(math.hypot(px - 512, py - 452) - 176) - 16
            else:
                cradle = min(math.hypot(px - 336, max(414 - py, 0)),
                             math.hypot(px - 688, max(414 - py, 0))) - 16
            stem = rounded_distance(px, py, 512, 696, 16, 68, 16)
            base = rounded_distance(px, py, 512, 764, 88, 16, 16)
            coverage = min(1, max(0, 0.5 - min(body, cradle, stem, base) / scale))
            if variant == 'dark':
                rows.extend((*ink, round(255 * coverage)))
            else:
                rows.extend(round(bg * (1 - coverage) + fg * coverage) for bg, fg in zip(background, ink))
    header = struct.pack('>IIBBBBB', size, size, 8, 6 if variant == 'dark' else 2, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def generate(destination=None):
    catalog = destination or Path(__file__).parent / 'Assets.xcassets'
    icon = catalog / 'AppIcon.appiconset'
    icon.mkdir(parents=True, exist_ok=True)
    (icon / 'AppIcon.png').unlink(missing_ok=True)  # Remove the previous generated placeholder.
    info = {'version': 1, 'author': 'voiceremote'}
    (catalog / 'Contents.json').write_text(json.dumps({'info': info}) + '\n')
    images = []
    for variant in ['light', 'dark', 'tinted']:
        filename = 'AppIcon-' + variant + '.png'
        entry = {'filename': filename, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}
        if variant != 'light':
            entry['appearances'] = [{'appearance': 'luminosity', 'value': variant}]
        images.append(entry)
        (icon / filename).write_bytes(render(variant))
    (icon / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}, indent=2) + '\n')


if __name__ == '__main__':
    generate()
