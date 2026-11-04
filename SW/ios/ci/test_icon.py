"""Original icon renderer: valid PNG structure and native appearance catalog."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('voice_icon', Path(__file__).resolve().parents[1] / 'Configuration/generate_icon.py')
icon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icon)


class IconTests(unittest.TestCase):
    def test_three_variants_have_correct_pixel_and_transparency_format(self):
        for variant in ['light', 'dark', 'tinted']:
            with self.subTest(variant=variant):
                data = icon.render(variant, size=64)
                self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
                width, height, depth, color = struct.unpack('>IIBB', data[16:26])
                self.assertEqual((width, height, depth, color), (64, 64, 8, 6 if variant == 'dark' else 2))
                start = 8; raw = b''
                while start < len(data):
                    count = struct.unpack('>I', data[start:start+4])[0]
                    kind, payload = data[start+4:start+8], data[start+8:start+8+count]
                    if kind == b'IDAT':
                        raw += payload
                    start += count + 12
                pixels = zlib.decompress(raw)
                stride = 4 if variant == 'dark' else 3
                self.assertEqual(len(pixels), 64 * (1 + 64 * stride))
                if variant == 'dark':
                    self.assertEqual(pixels[4], 0)  # Transparent background corner.
                if variant == 'tinted':
                    self.assertEqual(pixels[1], pixels[2]); self.assertEqual(pixels[2], pixels[3])

    def test_catalog_references_all_variants_as_single_1024_sources(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(icon, 'render', return_value=b'synthetic-fixture'):
            old = Path(directory) / 'AppIcon.appiconset/AppIcon.png'
            old.parent.mkdir(); old.write_bytes(b'synthetic old placeholder')
            icon.generate(Path(directory))
            self.assertFalse(old.exists())
            entries = json.loads((Path(directory) / 'AppIcon.appiconset/Contents.json').read_text())['images']
            self.assertEqual(len(entries), 3)
            self.assertEqual([e.get('appearances', [{}])[0].get('value') for e in entries], [None, 'dark', 'tinted'])
            for entry in entries:
                self.assertEqual(entry['size'], '1024x1024')
                self.assertTrue((Path(directory) / 'AppIcon.appiconset' / entry['filename']).is_file())
