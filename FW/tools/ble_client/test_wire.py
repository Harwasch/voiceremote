"""Synthetic fixtures; no adapter access or Bleak import."""
import unittest
from wire import fragments, input_event, phone_state, text, version_info

class WireTests(unittest.TestCase):
    def test_contract_phone_example(self):
        data = phone_state(42, link="BLE", error="Mic off")
        writes = list(fragments(data, 7, 20))
        expected = [
            "07 00 21 00 00 00 01 00 00 00 02 00 2a 00 00 00 04 41 75 74",
            "07 00 21 00 0e 00 6f 02 50 43 02 50 43 03 42 4c 45 07 4d 69",
            "07 00 21 00 1c 00 63 20 6f 66 66"]
        self.assertEqual(writes, [bytes.fromhex(s) for s in expected])

    def test_inputs(self):
        for event in range(6):
            data = bytes.fromhex("2a000000e8030000000101000000")
            data = data[:8] + bytes([event, 1, 1, int(event == 1), 0, 0])
            self.assertEqual(input_event(data)["event"], event)
        with self.assertRaises(ValueError):
            input_event(bytes(13))
        with self.assertRaises(ValueError):
            input_event(bytes.fromhex("2a000000e8030000010101000000"))

    def test_info(self):
        data = bytes.fromhex("0100ffff000102003f000101f000180100020000")
        info = version_info(data)
        self.assertEqual((info["width"], info["height"]), (240, 280))
        self.assertTrue(info["full_v1_capabilities"])
        data = data[:8] + b"\x3e" + data[9:]
        self.assertFalse(version_info(data)["full_v1_capabilities"])
        with self.assertRaises(ValueError):
            version_info(bytes(20))

    def test_bounds(self):
        for value in ("a\n", "\x7f", "\x85", "A" * 33):
            with self.assertRaises(ValueError):
                text(value, 32)
        self.assertEqual(text("🎙", 4), b"\x04\xf0\x9f\x8e\x99")
        for budget in (6, 513):
            with self.assertRaises(ValueError):
                list(fragments(phone_state(0), 0, budget))
        for kwargs in ({"arm": True}, {"recording": 1}, {"mode": 2}, {"target": ""}):
            with self.assertRaises(ValueError):
                phone_state(0, **kwargs)
        self.assertTrue(phone_state(0, capture=1, recording=1, arm=True))

if __name__ == "__main__":
    unittest.main()
