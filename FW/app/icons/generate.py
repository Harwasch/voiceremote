#!/usr/bin/env python3
"""Purpose: generate a seam-free A8 sparkle from the mock's cubic path.
Inputs: drawA/icon('ai') coordinates, Pillow. Verification: native PNG + IDF builds.
"""
from pathlib import Path
from PIL import Image, ImageDraw

size, supersample = 112, 4
points = []
for quadrant in range(4):
    for i in range(129):
        t = i / 128
        u = 1 - t
        x = 3 * u * u * t * 1.6 + 3 * u * t * t * 5.6 + t**3 * 16
        y = -u**3 * 16 - 3 * u * u * t * 5.6 - 3 * u * t * t * 1.6
        for _ in range(quadrant):
            x, y = -y, x
        points.append(((56 + x * 112 / 34) * supersample,
                       (56 + y * 112 / 34) * supersample))
image = Image.new('L', (size * supersample, size * supersample))
ImageDraw.Draw(image).polygon(points, fill=255)
image = image.resize((size, size), Image.Resampling.LANCZOS)
data = image.tobytes()
lines = [', '.join(f'0x{v:02x}' for v in data[i:i+16]) + ',' for i in range(0, len(data), 16)]
Path(__file__).with_name('sparkle.c').write_text('''/* Generated from the mock cubic path by generate.py; see README.md.
 * Purpose: A8 sparkle without independently antialiased triangle seams.
 * Inputs: mock geometry. Verified by native/firmware builds. */
#include "lvgl.h"
static const uint8_t alpha[] = {
''' + '\n'.join(lines) + '''
};
const lv_image_dsc_t vr_sparkle = {
    .header = {.magic=LV_IMAGE_HEADER_MAGIC, .cf=LV_COLOR_FORMAT_A8,
               .w=112, .h=112, .stride=112},
    .data_size=sizeof alpha, .data=alpha
};
''')
