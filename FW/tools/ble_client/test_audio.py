"""Synthetic transport, recovery and WAV tests; never opens an adapter."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import wave

from audio import AudioLoss, Reassembler, WavRecorder
from wire import BenchPolicy


def fragment(segment=1, frame=0, flags=5, offset=0, total=3, payload=b'abc'):
    return struct.pack('<IHBBHH', segment, frame, flags, 0, offset, total) + payload


def end(segment=1, frame=1):
    return fragment(segment, frame, 6, 0, 0, b'')


def input_value(seq, kind=0, capture=1, ptt=0, mode=0):
    return dict(seq=seq, event=kind, capture=capture, ptt=ptt, mode=mode, streaming=0, ms=seq*1000)


class FakeDecoder:
    def decode(self, packet, size, fec):
        assert packet and size == 320 and not fec
        return b'\0\0' * 320


class AudioTests(unittest.TestCase):
    def test_duplicates_and_end(self):
        r = Reassembler()
        a = fragment(flags=1, total=6)
        b = fragment(flags=5, offset=3, total=6, payload=b'def')
        self.assertIsNone(r.feed(a))
        self.assertIsNone(r.feed(a))
        self.assertEqual(r.feed(b).packet, b'abcdef')
        self.assertIsNone(r.feed(a))
        self.assertIsNone(r.feed(b))
        self.assertIsNone(r.feed(end()).packet)
        self.assertIsNone(r.feed(end()))
        self.assertIsNone(r.feed(a))
        self.assertEqual(r.feed(fragment(segment=2)).segment, 2)
        self.assertIsNone(r.feed(end(segment=1)))
        self.assertIsNone(r.feed(a))

    def test_missing_fragments_frames_and_conflicts(self):
        for value in [fragment(offset=1), fragment(frame=1, flags=4), end(),
                      fragment(flags=4), fragment(flags=7), fragment(total=513), b'bad',
                      fragment(segment=0), fragment(flags=1)]:
            with self.subTest(value=value), self.assertRaises(AudioLoss):
                Reassembler().feed(value)
        for bad in [fragment(flags=5, offset=4, total=7),
                    fragment(flags=1, total=6, payload=b'xxx'),
                    fragment(flags=1, total=7), end(),
                    fragment(segment=2), fragment(frame=1, flags=4)]:
            r = Reassembler()
            r.feed(fragment(flags=1, total=6))
            with self.subTest(bad=bad), self.assertRaises(AudioLoss):
                r.feed(bad)
        r = Reassembler(); r.feed(fragment())
        with self.assertRaises(AudioLoss):
            r.feed(fragment(payload=b'xyz'))
        with self.assertRaises(AudioLoss):
            r.feed(end(frame=2))

    def test_segment_ids_never_skip_or_reuse(self):
        r = Reassembler()
        with self.assertRaises(AudioLoss):
            r.feed(fragment(segment=2))
        r.reset()
        self.assertIsNone(r.feed(fragment(segment=2)))
        self.assertEqual(r.feed(fragment(segment=3)).segment, 3)
        with self.assertRaises(AudioLoss):
            r.feed(fragment(segment=4))  # missing END
        r.reset()
        self.assertEqual(r.feed(fragment(segment=5)).segment, 5)

    def test_watchdog_and_interrupted_wav(self):
        with tempfile.TemporaryDirectory() as tmp:
            reports = []
            recorder = WavRecorder(Path(tmp)/'test.wav', decoder_factory=FakeDecoder, report=reports.append)
            recorder.feed(fragment())
            with self.assertRaises(AudioLoss):
                recorder.reassembly.watchdog(recorder.reassembly.last_activity + 1.01)
            recorder.close(True, 'watchdog')
            files = list(Path(tmp).glob('*.wav'))
            self.assertEqual(len(files), 1)
            self.assertIn('interrupted', files[0].name)
            with wave.open(str(files[0]), 'rb') as wav:
                self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()), (1, 2, 16000, 320))
            self.assertIn('frames=1 gaps=1', reports[0])

    def test_missing_start_watchdog(self):
        recorder = WavRecorder(None, decoder_factory=FakeDecoder)
        recorder.expect_streaming(True)
        with self.assertRaises(AudioLoss):
            recorder.watchdog(recorder.expected_at + 1.01)
        recorder.expect_streaming(False)
        recorder.watchdog()

    def test_wrong_decoded_duration(self):
        class BadDecoder:
            def decode(self, *_): return b'\0\0'
        recorder = WavRecorder(None, decoder_factory=BadDecoder)
        with self.assertRaises(AudioLoss):
            recorder.feed(fragment())
        recorder.close(True, 'bad decoder')

    def test_client_ack_rearm_and_recovery(self):
        p = BenchPolicy(True)
        p.input(input_value(0))
        self.assertTrue(p.arm()); self.assertFalse(p.streaming_allowed())
        p.input(input_value(1, 1, ptt=1))
        self.assertTrue(p.arm())
        self.assertTrue(p.streaming_allowed())
        p.input(input_value(2, ptt=1))  # streaming snapshot: ack/write again, stays armed
        self.assertTrue(p.arm()); self.assertEqual(p.latest['seq'], 2)
        self.assertEqual(p.input(input_value(2)), (False, False))
        p.input(input_value(4, ptt=1))  # gap
        self.assertFalse(p.arm())
        p.input(input_value(5, ptt=1)); self.assertFalse(p.arm())
        p.input(input_value(6, 2)); p.input(input_value(7, 1, ptt=1)); self.assertTrue(p.arm())
        p.lose(); p.input(input_value(8, ptt=1)); self.assertFalse(p.arm())
        p.input(input_value(9, 2)); p.input(input_value(10, 4, capture=0)); self.assertFalse(p.arm())
        p.input(input_value(11, 4, capture=2)); self.assertTrue(p.arm())
        p.input(input_value(12, capture=2)); self.assertTrue(p.arm())
        p.lose(); p.input(input_value(13, capture=2)); self.assertFalse(p.arm())
        p.input(input_value(14, 4, capture=0)); p.input(input_value(15, 4, capture=2)); self.assertTrue(p.arm())
        for capture, ptt in [(1, 1), (2, 0)]:
            reconnect = BenchPolicy(True)
            reconnect.input(input_value(0, capture=capture, ptt=ptt))
            self.assertFalse(reconnect.arm())  # snapshot never creates a trigger

    def fixture_values(self, mtu, packet=None, drop=False):
        executable = os.environ.get('VR_FRAMER', str(Path(__file__).resolve().parents[2]/'build-host/audio_tests'))
        if not Path(executable).is_file():
            self.fail('build FW/build-host/audio_tests before Python round-trip tests')
        command = [executable, '--fixture-drop' if drop else '--fixture', str(mtu)]
        if packet is not None:
            command.append(packet.hex())
        data = subprocess.check_output(command)
        while data:
            size, = struct.unpack_from('<H', data)
            value, data = data[2:2+size], data[2+size:]
            self.assertEqual(len(value), size)
            self.assertLessEqual(size, mtu-3)
            yield value

    def test_firmware_to_python_round_trip(self):
        for mtu in (23, 64, 247, 517):
            r = Reassembler()
            events = [event for value in self.fixture_values(mtu) if (event := r.feed(value))]
            self.assertEqual([e.packet for e in events], [bytes(range(60))]*3 + [None])
            self.assertEqual([e.frame for e in events], [0, 1, 2, 3])

    def test_end_after_entirely_unsent_tail_is_clean(self):
        for mtu in (23, 247):
            r = Reassembler()
            events = [event for value in self.fixture_values(mtu, drop=True)
                      if (event := r.feed(value))]
            self.assertEqual([e.frame for e in events], [0, 1, 2, 3])
            self.assertIsNone(events[-1].packet)

    def test_real_opus_firmware_framing_to_wav(self):
        try:
            from opuslib_next import Encoder, APPLICATION_VOIP
        except ImportError:
            self.skipTest('real Opus test runs through the locked uv environment')
        # Curated synthetic silence, created in memory; no real audio fixture.
        encoder = Encoder(16000, 1, APPLICATION_VOIP)
        packet = encoder.encode(b'\0\0'*320, 320)
        for mtu in (23, 247):
            with tempfile.TemporaryDirectory() as tmp:
                reports = []
                recorder = WavRecorder(Path(tmp)/'opus.wav', report=reports.append)
                for value in self.fixture_values(mtu, packet):
                    recorder.feed(value)
                files = list(Path(tmp).glob('*.wav'))
                self.assertEqual(len(files), 1)
                with wave.open(str(files[0]), 'rb') as wav:
                    self.assertEqual(wav.getnframes(), 960)
                    self.assertEqual(wav.getframerate(), 16000)
                self.assertIn('frames=3 gaps=0', reports[0])


if __name__ == '__main__':
    unittest.main()
