"""Synthetic draft 1.1 fixtures, fake GATT and durable phone copies; no adapter."""
import asyncio
from dataclasses import replace
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

from offline import (Assembly, Copies, Metadata, Preempted, ReplyError, Transport,
                     progress, request_clock, request_list, request_fetch,
                     request_confirm, sync_pass)
from wire import fragments, input_event, version_info

M = bytes.fromhex('010000000000000007000000e803000000000000000000000000000000010500000001000000a0dd9776')
S = bytes.fromhex('0300000102')
G = bytes.fromhex('0800010000000000100000000000000020000000000001000000000000000500000007000000e803000000000000')


class Decoder:
    def decode(self, packet, samples, fec):
        return bytes(640)


class FakeRemote:
    def __init__(self, meta, data):
        self.meta, self.data = meta, data
        self.deleted = False
        self.confirmations = 0
        self.fetch_offsets = []
        self.fail_confirm = False
        self.preempt_fetch = False

    async def request(self, data):
        op = data[0]
        if op == 2:
            cursor = struct.unpack_from('<Q', data, 1)[0]
            if self.deleted or cursor >= self.meta.recording:
                raise ReplyError(2, 1)
            return b'\x02\x00' + self.meta.encode()
        if op == 3:
            _, recording, offset, maximum = struct.unpack('<BQIH', data)
            assert recording == self.meta.recording
            self.fetch_offsets.append(offset)
            if self.preempt_fetch:
                raise Preempted()
            part = self.data[offset:offset + min(maximum, 7)]
            return struct.pack('<BBQIH', 3, 0, recording, offset, len(part)) + part
        if op == 4:
            assert data == request_confirm(self.meta)
            self.deleted = True
            self.confirmations += 1
            if self.fail_confirm:
                self.fail_confirm = False
                raise TimeoutError()
            return b'\x04\x00'
        raise AssertionError(op)


class OfflineTests(unittest.TestCase):
    def test_contract_hex_round_trips(self):
        meta = Metadata.decode(M)
        self.assertEqual(meta.encode(), M)
        self.assertEqual(zlib.crc32(S), meta.crc)
        expected = [
            (request_clock(7, 1000, 1700000000000), '0107000000e8030000000000000068e5cf8b010000'),
            (request_list(), '020000000000000000'),
            (request_fetch(1, 0, 5), '030100000000000000000000000500'),
            (request_confirm(meta), '04010000000000000005000000a0dd9776'),
        ]
        logical = [bytes.fromhex(s) for _, s in expected]
        logical += [b'\x01\x00', b'\x02\x00' + M, b'\x02\x01',
                    bytes.fromhex('030001000000000000000000000005000300000102'),
                    b'\x04\x00', b'\x04\x00', b'\x03\x03', G]
        for actual, hexadecimal in expected:
            self.assertEqual(actual, bytes.fromhex(hexadecimal))
        for data in logical:
            assembly = Assembly(1, 512)
            result = None
            for fragment in fragments(data, 9, 20, minimum=1):
                result = assembly.feed(fragment)
            self.assertEqual(result, (9, data))
        self.assertEqual(list(fragments(request_list(), 9, 20, minimum=1)),
                         [bytes.fromhex('090009000000020000000000000000')])
        self.assertEqual(progress(G)['tick'], 1000)
        self.assertEqual(progress(G)['free'], 1048576)
        event = input_event(bytes.fromhex('2b000000fc030000000100010200'))
        self.assertTrue(event['offline'])
        self.assertFalse(event['streaming'])
        info = version_info(bytes.fromhex('0101ffff00010200bf000101f000180100020000'))
        self.assertTrue(info['offline'])
        self.assertEqual(info['contract'], '1.1')

    def test_minor_compatibility_reserved_fields(self):
        data = bytearray.fromhex('0101ffff00010200bf000101f000180100020000')
        data[1] = 2
        data[9] = 1
        self.assertTrue(version_info(data)['offline'])
        data[1] = 1
        with self.assertRaises(ValueError):
            version_info(data)
        data[0] = 2
        with self.assertRaises(ValueError):
            version_info(data)
        event = bytearray.fromhex('2b000000fc030000000100010200')
        event[12] = 0x82
        self.assertTrue(input_event(event, minor=2)['offline'])
        with self.assertRaises(ValueError):
            input_event(event, minor=1)
        event[12] = 3
        with self.assertRaises(ValueError):
            input_event(event, minor=2)

    def test_assembly_gaps_replacement_bounds(self):
        assembly = Assembly(2, 512)
        values = list(fragments(b'\x02\x00' + M, 3, 20, minimum=1))
        assembly.feed(values[0])
        with self.assertRaises(ValueError):
            assembly.feed(values[2])
        result = None
        for value in values:
            result = assembly.feed(value)
        self.assertEqual(result, (3, b'\x02\x00' + M))
        for value in (b'', struct.pack('<HHH', 1, 513, 0) + b'x',
                      struct.pack('<HHH', 1, 2, 2) + b'x'):
            with self.assertRaises(ValueError):
                assembly.feed(value)

    def test_verify_all_dimensions_and_torn_packet(self):
        meta = Metadata.decode(M)
        with tempfile.TemporaryDirectory() as directory:
            copies = Copies(directory, 'enrollment-A')
            copies.prepare(meta)
            copies.append(meta, 0, S)
            for invalid in (replace(meta, frames=2), replace(meta, size=6), replace(meta, crc=0)):
                with self.assertRaises(ValueError):
                    copies.verify(invalid, copies.paths(meta)[1])
            for damaged in (S[:-1], b'\x00\x00', b'\x03'):
                copies.paths(meta)[1].write_bytes(damaged)
                with self.assertRaises(ValueError):
                    copies.verify(meta, copies.paths(meta)[1])

    def test_resume_metadata_change_repeated_bytes_and_identity(self):
        meta = Metadata.decode(M)
        with tempfile.TemporaryDirectory() as directory:
            copies = Copies(directory, 'enrollment-A')
            self.assertEqual(copies.prepare(meta), 0)
            copies.append(meta, 0, S[:3])
            copies.append(meta, 0, S[:3])
            with self.assertRaises(ValueError):
                copies.append(meta, 0, b'xxx')
            reopened = Copies(directory, 'enrollment-A')
            self.assertEqual(reopened.prepare(meta), 3)
            other = Copies(directory, 'new-enrollment')
            self.assertNotEqual(copies.directory, other.directory)
            self.assertEqual(other.prepare(meta), 0)
            self.assertEqual(reopened.prepare(replace(meta, tick=1001)), 0)

    def test_short_discard_and_lost_confirm_idempotence(self):
        async def exercise():
            meta = Metadata.decode(M)
            with tempfile.TemporaryDirectory() as directory:
                copies = Copies(directory, 'enrollment-A')
                remote = FakeRemote(meta, S)
                remote.fail_confirm = True
                with self.assertRaises(TimeoutError):
                    await sync_pass(remote, copies, report=lambda _: None)
                state = json.loads(copies.paths(meta)[0].read_text())
                self.assertTrue(state['durable'])
                self.assertFalse(state['confirmed'])
                self.assertEqual(state['disposition'], 'discarded-short')
                self.assertFalse(list(copies.directory.glob('*.wav')))
                fetches = list(remote.fetch_offsets)
                await sync_pass(remote, Copies(directory, 'enrollment-A'), report=lambda _: None)
                self.assertEqual(remote.confirmations, 2)
                self.assertEqual(remote.fetch_offsets, fetches)
                self.assertTrue(json.loads(copies.paths(meta)[0].read_text())['confirmed'])
        asyncio.run(exercise())

    def test_resume_decode_sidecar_and_capture_preemption(self):
        async def exercise():
            data = S * 15
            meta = replace(Metadata.decode(M), size=len(data), frames=15, crc=zlib.crc32(data), mode=1)
            with tempfile.TemporaryDirectory() as directory:
                copies = Copies(directory, 'enrollment-A', decoder_factory=Decoder)
                copies.prepare(meta)
                copies.append(meta, 0, data[:13])
                remote = FakeRemote(meta, data)
                remote.preempt_fetch = True
                with self.assertRaises(Preempted):
                    await sync_pass(remote, copies, report=lambda _: None)
                self.assertEqual(copies.prepare(meta), 13)
                self.assertEqual(remote.confirmations, 0)
                remote.preempt_fetch = False
                await sync_pass(remote, copies, report=lambda _: None)
                self.assertEqual(remote.fetch_offsets[:2], [13, 13])
                state = json.loads(copies.paths(meta)[0].read_text())
                self.assertEqual(state['metadata']['mode'], 1)
                self.assertIn('unknown-boot7-tick1000-ai', state['wav'])
                self.assertTrue((copies.directory / state['wav']).is_file())
                self.assertTrue(state['confirmed'])
        asyncio.run(exercise())

    def test_transport_capture_cancels_assembly_and_ignores_late_reply(self):
        async def exercise():
            class Client:
                async def write_gatt_char(self, *_args, **_kwargs):
                    pass
            transport = Transport(Client(), report=lambda _: None)
            transport.off = False
            operation = asyncio.create_task(transport.request(request_fetch(1, 0, 5)))
            await asyncio.sleep(0)
            transaction = transport.transaction
            result = list(fragments(b'\x03\x00' + bytes(19), transaction, 20, minimum=1))
            transport.on_result(None, result[0])
            self.assertTrue(transport.result.data)
            transport.on_input(dict(status=1, event=0, capture=2))
            with self.assertRaises(Preempted):
                await operation
            transport.on_result(None, result[1])
            self.assertFalse(transport.result.data)
            self.assertEqual(transport.transaction, transaction)
        asyncio.run(exercise())


    def test_off_blocks_fetch_and_busy_reply_is_retryable(self):
        async def exercise():
            class Client:
                writes = 0
                async def write_gatt_char(self, *_args, **_kwargs):
                    self.writes += 1
            client = Client()
            transport = Transport(client, report=lambda _: None)
            with self.assertRaises(Preempted):
                await transport.request(request_fetch(1, 0, 5))
            self.assertEqual(client.writes, 0)
            transport.off = False
            operation = asyncio.create_task(transport.request(request_fetch(1, 0, 5)))
            await asyncio.sleep(0)
            for value in fragments(b'\x03\x03', transport.transaction, 20, minimum=1):
                transport.on_result(None, value)
            with self.assertRaises(ReplyError) as caught:
                await operation
            self.assertEqual(caught.exception.status, 3)
        asyncio.run(exercise())

    def test_off_snapshots_preserve_metadata_requests_but_cancel_fetch(self):
        async def exercise():
            class Client:
                async def write_gatt_char(self, *_args, **_kwargs):
                    pass
            transport = Transport(Client(), report=lambda _: None)
            idle_off = dict(status=0, event=0, capture=0)
            metadata = Metadata.decode(M)
            for request, reply in ((request_list(), b'\x02\x00' + M),
                                   (request_clock(7, 1000, 1700000000000), b'\x01\x00'),
                                   (request_confirm(metadata), b'\x04\x00')):
                operation = asyncio.create_task(transport.request(request))
                await asyncio.sleep(0)
                for fragment in fragments(reply, transport.transaction, 20, minimum=1):
                    transport.on_input(idle_off)
                    transport.on_result(None, fragment)
                self.assertEqual(await operation, reply)
            transport.off = False
            operation = asyncio.create_task(transport.request(request_fetch(1, 0, 5)))
            await asyncio.sleep(0)
            result = list(fragments(b'\x03\x00' + bytes(19), transport.transaction,
                                    20, minimum=1))
            transport.on_result(None, result[0])
            self.assertTrue(transport.result.data)
            transport.on_input(idle_off)
            with self.assertRaises(Preempted):
                await operation
            self.assertFalse(transport.result.data)
            transport.on_result(None, result[1])
            self.assertFalse(transport.result.data)
        asyncio.run(exercise())

    def test_idle_progress_clears_capture(self):
        transport = Transport(None, report=lambda _: None)
        transport.on_input(dict(status=2, event=0, capture=2))
        self.assertTrue(transport.capturing)
        for fragment in fragments(G, 1, 20, minimum=1):
            transport.on_progress(None, fragment)
        self.assertFalse(transport.capturing)

    def test_list_exhausted_status_rejected_for_other_opcodes(self):
        async def exercise():
            class Client:
                async def write_gatt_char(self, *_args, **_kwargs):
                    pass
                async def start_notify(self, *_args):
                    pass
                async def stop_notify(self, *_args):
                    pass
            transport = Transport(Client(), report=lambda _: None)
            for request in (request_clock(7, 1000, 1700000000000),
                            request_confirm(Metadata.decode(M))):
                operation = asyncio.create_task(transport.request(request))
                await asyncio.sleep(0)
                for fragment in fragments(bytes((request[0], 1)), transport.transaction,
                                          20, minimum=1):
                    transport.on_result(None, fragment)
                with self.assertRaisesRegex(ValueError, 'opcode/status/length'):
                    await operation
                self.assertTrue(transport.resubscribe)
        asyncio.run(exercise())

    def test_real_opus_offline_wav_and_durable_id_conflict(self):
        from opuslib_next import Encoder
        encoder = Encoder(16000, 1, 'voip')
        packet = encoder.encode(bytes(640), 320)
        data = (struct.pack('<H', len(packet)) + packet) * 15
        meta = replace(Metadata.decode(M), size=len(data), frames=15, crc=zlib.crc32(data))
        with tempfile.TemporaryDirectory() as directory:
            copies = Copies(directory, 'enrollment-A')
            copies.prepare(meta)
            copies.append(meta, 0, data)
            state = copies.finish(meta)
            self.assertTrue((copies.directory / state['wav']).is_file())
            with self.assertRaises(ValueError):
                copies.prepare(replace(meta, mode=1))
            self.assertTrue(copies.paths(meta)[2].is_file())

if __name__ == '__main__':
    unittest.main()
