#!/usr/bin/env python3
"""Unattended StopWatch regression; existing owner bond and TEST HOOK build required.

Uses POSIX serial and the locked BLE client's policy, framing, decoder and durable
sync implementation. No enrollment, audio stimulus, flashing or adapter setup.
"""
import argparse
import asyncio
import contextlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ble_client'))
from audio import WavRecorder
from offline import Copies, Metadata, Preempted, ReplyError, Transport, sync_pass, request_fetch, request_list
from wire import AUDIO, INFO, INPUT, PHONE, BenchPolicy, fragments, input_event, phone_state, version_info


class Serial:
    """Nonblocking USB CDC/JTAG serial; deliberately does not toggle DTR/RTS."""
    def __init__(self, port, directory):
        self.port, self.fd = port, None
        self.lines = []
        self.pending = bytearray()
        self.log = (directory / 'serial.log').open('w')

    def open(self):
        self.fd = os.open(self.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        attrs = termios.tcgetattr(self.fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[4] = attrs[5] = termios.B115200
        attrs[6][termios.VMIN] = attrs[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)

    def send(self, command):
        if command not in 'oprduhtx' or len(command) != 1:
            raise ValueError('unknown test command')
        if self.fd is None:
            raise RuntimeError('serial unavailable')
        if os.write(self.fd, command.encode('ascii')) != 1:
            raise RuntimeError('short serial command')

    async def collect(self):
        while True:
            try:
                if self.fd is None:
                    self.open()
                data = os.read(self.fd, 8192)
                if not data and os.stat(self.port).st_ino != os.fstat(self.fd).st_ino:
                    os.close(self.fd)
                    self.fd = None
                    self.pending.clear()
                if data:
                    self.pending.extend(data)
                    while b'\n' in self.pending:
                        line, _, rest = self.pending.partition(b'\n')
                        self.pending = bytearray(rest)
                        text = re.sub(r'\x1b\[[0-9;]*m', '', line.decode('utf-8', 'replace').rstrip())
                        self.lines.append(text)
                        self.log.write(text + '\n')
                        self.log.flush()
            except BlockingIOError:
                pass
            except OSError:
                if self.fd is not None:
                    os.close(self.fd)
                    self.fd = None
                self.pending.clear()  # never join lines across USB re-enumeration
            await asyncio.sleep(.01)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        self.log.close()


async def wait_for(predicate, description, timeout=15, session=None):
    deadline = time.monotonic() + timeout
    while not predicate():
        if session:
            session.check()
        if time.monotonic() >= deadline:
            raise TimeoutError(description)
        await asyncio.sleep(.02)
    if session:
        session.check()


class Session:
    def __init__(self, address, output, number):
        self.address, self.output, self.number = address, output, number
        self.policy = BenchPolicy(True)
        self.changed = asyncio.Event()
        self.latest = None
        self.fatal = None
        self.frames = 0
        self.reports = []
        self.fetch_offsets = []
        self.transaction = 0
        self.worker = None
        self.client = None

    def check(self):
        if self.fatal:
            raise self.fatal
        if hasattr(self, 'recorder'):
            self.recorder.watchdog()
        if not self.client.is_connected:
            raise RuntimeError('unexpected BLE disconnect')

    def on_input(self, _characteristic, value):
        try:
            event = input_event(bytes(value), self.info['minor'])
            accepted, loss = self.policy.input(event)
            if accepted:
                if loss:
                    raise ValueError('Input sequence/transition loss')
                self.latest = event
                self.transport.on_input(event)
                self.recorder.expect_streaming(event['streaming'])
                self.changed.set()
        except Exception as exc:
            self.fatal = exc

    def on_audio(self, _characteristic, value):
        try:
            is_end = len(value) >= 7 and value[6] & 2
            if not is_end and not self.policy.streaming_allowed():
                raise ValueError('Audio while OFF/disarmed/offline')
            before = self.recorder.frames
            self.recorder.feed(bytes(value))
            self.frames += max(0, self.recorder.frames - before)
        except Exception as exc:
            self.fatal = exc

    async def write_state(self):
        latest = self.policy.latest
        arm = self.policy.arm()
        capture = latest['capture'] if latest else 0
        data = phone_state(latest['seq'] if latest else 0, capture=capture,
                           recording=1 if arm else (0 if capture == 0 else 2),
                           mode=latest['mode'] if latest else 0, arm=arm,
                           snapshot=self.policy.snapshot_needed, target='HIL')
        self.transaction += 1
        for value in fragments(data, self.transaction, self.budget):
            await self.client.write_gatt_char(PHONE, value, response=True)

    async def acknowledge(self):
        try:
            while True:
                await self.changed.wait()
                self.changed.clear()
                await self.write_state()
                self.recorder.watchdog()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.fatal = exc

    async def connect(self):
        # Import lazily: fake/unit tests never need Bleak or a Bluetooth adapter.
        from bleak import BleakClient
        self.recorder = WavRecorder(self.output / f'live-{self.number}.wav', report=self.reports.append)
        self.client = BleakClient(self.address, timeout=30)
        try:
            await self.client.connect()
            # Existing bond only; intentionally no pairing agent or user prompts.
            self.info = version_info(bytes(await self.client.read_gatt_char(INFO)))
            if not self.info['offline'] or not self.info['full_v1_capabilities']:
                raise RuntimeError('requires functional StopWatch with offline capability')
            self.budget = min(512, self.client.mtu_size - 3)
            self.transport = Transport(self.client, self.budget, self.info['minor'])
            request = self.transport.request

            async def tracked(data):
                if data[0] == 3:
                    self.fetch_offsets.append(struct.unpack_from('<I', data, 9)[0])
                return await request(data)

            self.transport.request = tracked
            await self.client.start_notify(INPUT, self.on_input)
            await self.client.start_notify(AUDIO, self.on_audio)
            await self.transport.subscribe()
            await self.write_state()
            self.worker = asyncio.create_task(self.acknowledge())
            await wait_for(lambda: self.latest is not None, 'initial snapshot', session=self)
            await wait_for(lambda: self.transport.snapshot is not None, 'offline progress', session=self)
        except BaseException:
            await self.close()
            raise
        return self

    async def close(self):
        if self.worker:
            self.worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.worker
        if self.client:
            await self.client.disconnect()
        if hasattr(self, 'recorder'):
            self.recorder.close(True, 'intentional HIL link drop')
        (self.output / f'ble-{self.number}.log').write_text('\n'.join(self.reports) + '\n')


class FetchInterrupted(Exception):
    pass


class InterruptCopies(Copies):
    """Interrupt only after the first fetched chunk has actually been fsynced."""
    def append(self, meta, offset, data):
        super().append(meta, offset, data)
        self.interrupted_meta = meta
        self.resume_offset = offset + len(data)
        if self.resume_offset >= meta.size:
            raise ValueError('record too short to exercise interrupted fetch')
        raise FetchInterrupted()


def durable_states(copies):
    return [json.loads(p.read_text()) for p in sorted(copies.directory.glob('[0-9]*.json'))]


def verify_copies(copies, previous, *, interrupted=False):
    states = durable_states(copies)
    new = [s for s in states if s['metadata']['recording'] not in previous]
    if len(new) != 1:
        raise ValueError(f'expected exactly one new recording, got {len(new)}')
    state = new[0]
    meta = Metadata(**state['metadata'])
    copies.verify(meta, copies.paths(meta)[2])
    if not state.get('durable') or not state.get('confirmed') or meta.frames < 15 or not state.get('wav'):
        raise ValueError('missing verified durable audio/deletion/WAV')
    if bool(meta.flags & 2) != interrupted:
        raise ValueError('unexpected interrupted flag')
    return meta


class Runner:
    steps = ('hook boot', 'live streaming and clean OFF END', 'live start / link drop',
             'reconnect while recording', 'finalize / sync / verify', 'idempotent re-sync',
             'interrupted fetch', 'resume after interrupted fetch', 'OFF during offline',
             'reboot mid-recording', 'serial stats')

    def __init__(self, serial, address, identity, output, *, session_factory=Session, pause=asyncio.sleep):
        self.serial, self.address, self.identity, self.output = serial, address, identity, output
        self.session_factory, self.pause = session_factory, pause
        self.session = None
        self.number = 0
        self.results = {}

    async def connect(self):
        self.number += 1
        self.session = await self.session_factory(self.address, self.output, self.number).connect()
        return self.session

    async def disconnect(self):
        if self.session:
            await self.session.close()
            self.session = None

    async def command(self, command):
        start = len(self.serial.lines)
        self.serial.send(command)
        await wait_for(lambda: any(f'TEST BUILD command={command}' in l or command == 'x' and 'USB local-input hook ENABLED' in l for l in self.serial.lines[start:]),
                       f'hook acknowledgement {command}')
        await self.pause(.15)  # 25 ms debounce + input/render scheduling
        if self.session:
            self.session.check()

    async def offline_record(self, seconds=3):
        await self.command('o')
        await self.command('u')
        start = len(self.serial.lines)
        await self.command('r')
        await wait_for(lambda: any('capture started' in l for l in self.serial.lines[start:]),
                       'offline acquisition')
        await self.pause(seconds)

    async def idle(self):
        await self.command('o')
        await self.command('p')  # idle/up: fetch forbidden in OFF
        if self.session:
            s = self.session
            await wait_for(lambda: s.latest['capture'] == 1 and not s.latest['offline'], 'idle after local OFF', session=s)
            await wait_for(lambda: not s.transport.capturing, 'idle progress', session=s)
        await self.pause(.5)  # writer finalization; sync still rejects busy replies

    async def sync(self, copies):
        s = self.session
        deadline = time.monotonic() + 15
        while True:
            try:
                await sync_pass(s.transport, copies)
                break
            except ReplyError as exc:
                if exc.status not in (2, 3) or time.monotonic() >= deadline:
                    raise
                await self.pause(.2)
        s.check()

    async def run(self):
        copies = Copies(self.output / 'copies', self.identity)
        previous = {s['metadata']['recording'] for s in durable_states(copies)}
        step = self.steps[0]
        try:
            # Boot marker proves this is a hook build; no blind sleep assumption.
            start = len(self.serial.lines)
            await self.command('x')
            await wait_for(lambda: any('USB local-input hook ENABLED' in l for l in self.serial.lines[start:]),
                           'TEST BUILD boot marker', timeout=30)
            await wait_for(lambda: self.serial.fd is not None, 'USB reopen')
            await self.command('o'); await self.command('u'); await self.command('p')
            s = await self.connect()
            if s.transport.snapshot['waiting']:
                raise ValueError('requires empty remote journal; retain/sync old records separately')
            self.passed(step)

            step = self.steps[1]
            await self.command('r')
            await wait_for(lambda: s.latest['streaming'] and s.frames >= 50, 'live frames', session=s)
            await self.pause(2)
            await self.command('o')
            await wait_for(lambda: any('gaps=0' in r for r in s.reports), 'clean END with queued-tail discard', session=s)
            self.passed(step)

            step = self.steps[2]
            before = s.frames
            await self.command('r')
            await wait_for(lambda: s.latest['streaming'] and s.frames >= before + 50, 'second live start', session=s)
            start = len(self.serial.lines)
            await self.disconnect()  # deliberately no phone stop write
            await wait_for(lambda: any('capture started' in l for l in self.serial.lines[start:]), 'link-loss offline start')
            await self.pause(3)
            self.passed(step)

            step = self.steps[3]
            s = await self.connect()
            await wait_for(lambda: s.latest['offline'], 'locally owned recording survives reconnect', session=s)
            await self.pause(1)
            if s.frames or s.latest['streaming']:
                raise ValueError('offline record spliced into live Audio')
            try:
                await s.transport.request(request_list())
            except Preempted:
                pass
            else:
                raise ValueError('sync available during open recording')
            self.passed(step)

            step = self.steps[4]
            await self.idle()
            await s.transport.set_clock()
            await self.sync(copies)
            first = verify_copies(copies, previous)
            if first.mode != 0:
                raise ValueError('capture mode changed across reconnect')
            previous.add(first.recording)
            self.passed(step)

            step = self.steps[5]
            before = durable_states(copies)
            await self.sync(copies)
            if durable_states(copies) != before:
                raise ValueError('re-sync changed durable IDs/metadata')
            self.passed(step)

            step = self.steps[6]
            await self.disconnect()
            await self.offline_record(seconds=5)
            await self.idle()
            s = await self.connect()
            partial = InterruptCopies(self.output / 'copies', self.identity)
            try:
                await self.sync(partial)
            except FetchInterrupted:
                pass
            else:
                raise ValueError('fetch did not interrupt')
            if partial.prepare(partial.interrupted_meta) != partial.resume_offset:
                raise ValueError('partial not durable')
            await self.disconnect()
            self.passed(step)

            step = self.steps[7]
            s = await self.connect()
            await self.sync(copies)
            if not s.fetch_offsets or s.fetch_offsets[0] != partial.resume_offset:
                raise ValueError('fetch did not resume at first missing byte')
            second = verify_copies(copies, previous)
            previous.add(second.recording)
            self.passed(step)

            step = self.steps[8]
            await self.disconnect()
            await self.offline_record()
            await self.command('o')
            s = await self.connect()
            await wait_for(lambda: s.latest['capture'] == 0 and not s.latest['offline'], 'OFF stopped acquisition', session=s)
            try:
                await s.transport.request(request_fetch(second.recording + 1, 0))
            except Preempted:
                pass
            else:
                raise ValueError('fetch allowed in OFF')
            await self.command('p')
            await wait_for(lambda: s.latest['capture'] == 1, 'PTT idle', session=s)
            await self.sync(copies)
            third = verify_copies(copies, previous)
            previous.add(third.recording)
            self.passed(step)

            step = self.steps[9]
            old_boot = s.transport.snapshot['boot']
            await self.disconnect()
            await self.offline_record()
            start = len(self.serial.lines)
            await self.command('x')
            await wait_for(lambda: any('USB local-input hook ENABLED' in l for l in self.serial.lines[start:]), 'reboot marker', timeout=30)
            await self.command('u'); await self.command('p')
            s = await self.connect()
            if s.transport.snapshot['boot'] <= old_boot or s.latest['offline'] or s.latest['streaming']:
                raise ValueError('reboot restarted capture or boot ID did not advance')
            await self.sync(copies)
            recovered = verify_copies(copies, previous, interrupted=True)
            if recovered.recording <= third.recording or recovered.boot != old_boot:
                raise ValueError('record ID reuse or capture boot changed')
            self.passed(step)

            step = self.steps[10]
            await self.pause(5.5)
            lines = [l for l in self.serial.lines if any(k in l for k in ('timing:', 'audio:', 'offline:'))]
            (self.output / 'serial-stats.log').write_text('\n'.join(lines) + '\n')
            if not any('timing:' in l for l in lines):
                raise ValueError('missing timing stats: build with REMOTE_TIMING=ON')
            if any(re.search(r'(?:flush_errors|rejects)=[1-9]', l) for l in lines):
                raise ValueError('display flush failure or phone barrier rejection')
            if any('storage status=' in l or 'overflow' in l.lower() for l in lines):
                raise ValueError('storage/audio overflow/failure in serial stats')
            self.passed(step)
        except Exception as exc:
            self.results[step] = f'FAIL: {exc}'
            print(f'FAIL {step}: {exc}', flush=True)
        finally:
            await self.disconnect()
            for name in self.steps:
                if name not in self.results:
                    self.results[name] = 'FAIL: blocked by earlier failure'
                    print(f'FAIL {name}: blocked by earlier failure', flush=True)
            (self.output / 'results.json').write_text(json.dumps(self.results, indent=2) + '\n')
        return all(value == 'PASS' for value in self.results.values())

    def passed(self, step):
        self.results[step] = 'PASS'
        print(f'PASS {step}', flush=True)


async def main_async(args):
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    serial = Serial(args.port, output)
    collector = asyncio.create_task(serial.collect())
    try:
        await wait_for(lambda: serial.fd is not None, 'serial port open')
        return await Runner(serial, args.address, args.remote_id, output).run()
    finally:
        collector.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await collector
        serial.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--address', required=True)
    parser.add_argument('--remote-id', required=True, help='existing stable enrollment identity')
    parser.add_argument('--output', default=f'AI/scratch/offline-hil-{int(time.time())}', help='new output directory')
    args = parser.parse_args()
    try:
        return 0 if asyncio.run(main_async(args)) else 1
    except Exception as exc:
        print(f'FAIL setup: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
