"""Purpose: reproduce original installer glyph assets. Inputs: geometry below.
Verified: generated PNG/ICO bytes match the checked-in assets.
"""
import struct
import zlib
from pathlib import Path

SIZE = 128
pixels = bytearray()
for y in range(SIZE):
    pixels.append(0)  # PNG filter: none
    for x in range(SIZE):
        glyph = (
            (26 <= x < 36 and 25 <= y < 102)
            or (26 <= x < 80 and (25 <= y < 35 or 92 <= y < 102))
            or (80 <= x < 90 and 35 <= y < 92)
        )
        pixels.extend((128, 224, 188, 255) if glyph else (17, 24, 39, 255))


def chunk(kind, data):
    return (
        struct.pack(">I", len(data)) + kind + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
)
root = Path(__file__).parent
(root / "icon.png").write_bytes(png)
(root / "icon.ico").write_bytes(
    struct.pack("<HHH", 0, 1, 1)
    + struct.pack("<BBBBHHII", 128, 128, 0, 0, 1, 32, len(png), 22) + png
)
