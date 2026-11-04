"""Synthetic serial/BLE tests; never access a serial device or Bluetooth adapter."""
import asyncio
from dataclasses import asdict
import json
import os
from pathlib import Path
import pty
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

import run_offline as hil
from offline import Copies, Metadata, Preempted, ReplyError
from audio import WavRecorder


class Decoder:
    def decode(self, packet, size, fec):
        assert packet and size == 320 and not fec
        return bytes(640)


class FakeCopies(Copies):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, decoder_factory=Decoder, **kwargs)


class World:
    def __init__(self):
        self.lines = []
        self.fd = 1
        self.capture = 1
        self.ptt = False
        self.boot = 1
        self.next_id = 1
        self.active = False
        self.offline = False
        self.session = None
        self.records = {}
        self.commands = []
        self.fetches = []
        self.confirmations = []
        self.drop_audio = False

    def update(self):
        if self.session:
            s = self.session
            s.latest = dict(capture=self.capture, offline=self.offline,
                            streaming=self.active and not self.offline)
            s.transport.capturing = self.active
            s.transport.snapshot = dict(boot=self.boot, waiting=len(self.records))

    def finalize(self, interrupted=False):
        if self.active and self.offline:
            data = (struct.pack('<H', 60) + bytes(60)) * 250
            meta = Metadata(self.next_id, self.boot, 1000, 0, 0, 3 if interrupted else 1,
                            len(data), 250, zlib.crc32(data))
            self.records[self.next_id] = (meta, data)
            self.next_id += 1
        self.active = self.offline = False

    def send(self, command):
        self.commands.append(command)
        self.lines.append(f'test_hook: TEST BUILD command={command}')
        if command == 'x':
            self.finalize(True)
            self.boot += 1
            self.capture = 0
            self.lines.append('test_hook: TEST BUILD: USB local-input hook ENABLED')
        elif command == 'o':
            if self.session and self.active and not self.offline:
                self.session.reports.append('segment=1 frames=100 gaps=0')
            self.finalize()
            self.capture = 0
        elif command == 'p':
            self.capture = 1
        elif command == 'd' and self.session and self.capture == 1:
            self.ptt = True
            self.session.frames += 250
        elif command == 'u' and self.session and self.ptt and self.capture == 1:
            self.ptt = False
            self.session.reports.append('segment=2 frames=250 gaps=0')
        elif command == 'u':
            self.ptt = False
        elif command == 'r':
            self.capture = 2
            self.active = True
            self.offline = self.session is None
            if self.offline:
                self.lines.append('offline: capture started mode=0')
            elif not self.drop_audio:
                self.session.frames += 100
        self.lines.append('timing: redraw=100/200 flush_errors=0 rejects=0')
        self.update()


class FakeTransport:
    def __init__(self, session, world):
        self.session, self.world = session, world
        self.snapshot = None
        self.capturing = False

    async def set_clock(self):
        pass

    async def request(self, data):
        w = self.world
        op = data[0]
        if w.active or op == 3 and w.capture == 0:
            raise Preempted()
        if op == 2:
            cursor = struct.unpack_from('<Q', data, 1)[0]
            ids = [i for i in w.records if i > cursor]
            if not ids:
                raise ReplyError(2, 1)
            return b'\x02\0' + w.records[min(ids)][0].encode()
        if op == 3:
            recording, offset, maximum = struct.unpack_from('<QIH', data, 1)
            self.session.fetch_offsets.append(offset)
            w.fetches.append(offset)
            payload = w.records[recording][1][offset:offset+maximum]
            return b'\x03\0' + struct.pack('<QIH', recording, offset, len(payload)) + payload
        if op == 4:
            recording, size, crc = struct.unpack_from('<QII', data, 1)
            meta, _ = w.records[recording]
            assert (meta.size, meta.crc) == (size, crc)
            w.confirmations.append(recording)
            del w.records[recording]
            return b'\x04\0'
        raise AssertionError(op)


class FakeSession:
    def __init__(self, world, address, output, number):
        self.world = world
        self.frames = 0
        self.reports = []
        self.fetch_offsets = []
        self.transport = FakeTransport(self, world)

    async def connect(self):
        self.world.session = self
        self.world.update()
        return self

    def check(self):
        pass

    async def close(self):
        w = self.world
        if w.active and not w.offline:
            w.offline = True
            w.lines.append('offline: capture started mode=0')
        w.session = None


class RunnerTests(unittest.IsolatedAsyncioTestCase):
    async def test_whole_procedure_with_fake_serial_and_ble(self):
        with tempfile.TemporaryDirectory() as root:
            world = World()
            async def pause(_seconds):
                pass
            factory = lambda *args: FakeSession(world, *args)
            with patch.object(hil, 'Copies', FakeCopies):
                runner = hil.Runner(world, 'fake', 'synthetic-enrollment', Path(root),
                                    session_factory=factory, pause=pause)
                self.assertTrue(await runner.run())
            self.assertEqual(list(runner.results.values()), ['PASS'] * len(runner.steps))
            self.assertEqual(world.confirmations, [1, 2, 3, 4])
            self.assertFalse(world.records)
            self.assertIn(496, world.fetches)  # durable interrupted chunk resumes here
            states = hil.durable_states(FakeCopies(Path(root)/'copies', 'synthetic-enrollment'))
            self.assertEqual([s['metadata']['flags'] for s in states], [1, 1, 1, 3])
            self.assertEqual(world.commands.count('x'), 2)
            self.assertTrue((Path(root)/'serial-stats.log').is_file())

    async def test_failure_is_non_success_and_all_steps_reported(self):
        with tempfile.TemporaryDirectory() as root:
            world = World()
            world.records[7] = (None, b'')  # journal not empty: fail before new recording
            async def pause(_seconds): pass
            with patch.object(hil, 'Copies', FakeCopies):
                runner = hil.Runner(world, 'fake', 'synthetic', Path(root),
                                    session_factory=lambda *args: FakeSession(world, *args), pause=pause)
                self.assertFalse(await runner.run())
            self.assertEqual(len(runner.results), len(runner.steps))
            self.assertTrue(all(v.startswith('FAIL') for v in runner.results.values()))
            self.assertEqual(world.confirmations, [])
            self.assertIsNone(world.session)

    async def test_serial_pty_and_command_validation(self):
        with tempfile.TemporaryDirectory() as root:
            master, slave = pty.openpty()
            serial = hil.Serial(os.ttyname(slave), Path(root))
            serial.open()
            collector = asyncio.create_task(serial.collect())
            try:
                os.write(master, b'\x1b[31mtiming: rejects=0\x1b[0m\n')
                await hil.wait_for(lambda: bool(serial.lines), 'fake serial', timeout=1)
                self.assertEqual(serial.lines, ['timing: rejects=0'])
                serial.send('r')
                self.assertEqual(os.read(master, 1), b'r')
                with self.assertRaises(ValueError): serial.send('rr')
                with self.assertRaises(ValueError): serial.send('z')
            finally:
                collector.cancel()
                with self.assertRaises(asyncio.CancelledError): await collector
                serial.close()
                os.close(master); os.close(slave)
            self.assertEqual((Path(root)/'serial.log').read_text(), 'timing: rejects=0\n')

    async def test_real_session_accepts_end_after_off_without_closing_early(self):
        s = hil.Session('fake', Path('.'), 1)
        s.info = {'minor': 1}
        class Transport:
            def on_input(self, event): pass
        s.transport = Transport()
        s.recorder = WavRecorder(None, decoder_factory=Decoder, report=s.reports.append)
        def event(seq, kind=0, capture=1, ptt=0, status=0):
            return struct.pack('<II6B', seq, 0, kind, capture, 0, ptt, status, 0)
        s.on_input(None, event(0))
        s.on_input(None, event(1, 1, ptt=1))
        s.on_input(None, event(2, ptt=1, status=1))
        s.on_audio(None, struct.pack('<IHBBHH', 1, 0, 5, 0, 0, 3) + b'abc')
        s.on_input(None, event(3, 4, capture=0, ptt=1))
        self.assertIsNotNone(s.recorder.segment)
        s.on_audio(None, struct.pack('<IHBBHH', 1, 1, 6, 0, 0, 0))
        self.assertIsNone(s.fatal)
        self.assertEqual(s.frames, 1)
        self.assertIn('gaps=0', s.reports[0])
        # A post-OFF data packet must still fail, regardless of valid framing.
        s.on_audio(None, struct.pack('<IHBBHH', 2, 0, 5, 0, 0, 3) + b'abc')
        self.assertIsInstance(s.fatal, ValueError)

    async def test_timeout_never_counts_as_pass(self):
        with self.assertRaises(TimeoutError):
            await hil.wait_for(lambda: False, 'missing event', timeout=.001)


if __name__ == '__main__':
    unittest.main()
