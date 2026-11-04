"""Draft 1.1 deferred-transfer simulator; no STT, insertion or authority effects."""
import asyncio
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import struct
import time
import wave
import zlib

from wire import fragments, OFFLINE_CONTROL, OFFLINE_RESULT, OFFLINE_PROGRESS


class Preempted(Exception):
    """Capture canceled a request; restart listing after capture."""


class ReplyError(Exception):
    def __init__(self, opcode, status):
        super().__init__(f'offline opcode={opcode} status={status}')
        self.opcode, self.status = opcode, status


class Assembly:
    def __init__(self, minimum, maximum):
        self.minimum, self.maximum = minimum, maximum
        self.clear()

    def clear(self):
        self.transaction = None
        self.total = 0
        self.data = bytearray()

    def feed(self, value):
        if len(value) < 7:
            raise ValueError('short offline envelope')
        transaction, total, offset = struct.unpack_from('<HHH', value)
        payload = value[6:]
        if not self.minimum <= total <= self.maximum or offset + len(payload) > total:
            raise ValueError('invalid offline envelope bounds')
        if offset == 0:
            self.transaction, self.total, self.data = transaction, total, bytearray()
        if transaction != self.transaction or total != self.total or offset != len(self.data):
            raise ValueError('offline envelope gap/overlap/transaction mismatch')
        self.data.extend(payload)
        if len(self.data) == total:
            data = bytes(self.data)
            self.clear()
            return transaction, data
        return None


@dataclass(frozen=True)
class Metadata:
    recording: int
    boot: int
    tick: int
    utc: int
    mode: int
    flags: int
    size: int
    frames: int
    crc: int

    @classmethod
    def decode(cls, data):
        if len(data) != 42:
            raise ValueError('metadata must be 42 bytes')
        result = cls(*struct.unpack('<QIQQBBIII', data))
        if (not result.recording or not result.boot or result.mode > 1
                or result.flags not in (1, 3) or not result.frames
                or result.size < result.frames * 3 or result.utc > 253402300799999):
            raise ValueError('invalid metadata')
        return result

    def encode(self):
        return struct.pack('<QIQQBBIII', *asdict(self).values())


def progress(data, minor=1):
    if len(data) != 46:
        raise ValueError('progress must be 46 bytes')
    flags, reserved, waiting, free, total, recording, offset, boot, tick = struct.unpack('<BBIQQQIIQ', data)
    if (reserved or (flags & ~31 if minor <= 1 else False) or flags & 3 == 3
            or free > total or not boot):
        raise ValueError('invalid progress')
    return dict(flags=flags & 31, waiting=waiting, free=free, total=total,
                recording=recording, offset=offset, boot=boot, tick=tick)


def request_clock(boot, tick, utc):
    if not boot or not 0 < utc <= 253402300799999:
        raise ValueError('invalid clock sample')
    return struct.pack('<BIQQ', 1, boot, tick, utc)


def request_list(cursor=0):
    return struct.pack('<BQ', 2, cursor)


def request_fetch(recording, offset, maximum=496):
    if not recording or not 1 <= maximum <= 496:
        raise ValueError('invalid fetch request')
    return struct.pack('<BQIH', 3, recording, offset, maximum)


def request_confirm(meta):
    return struct.pack('<BQII', 4, meta.recording, meta.size, meta.crc)


class Transport:
    """One outstanding operation, with immediate Input-driven capture cancellation."""
    def __init__(self, client, budget=20, minor=1, report=print):
        self.client, self.budget, self.minor, self.report = client, budget, minor, report
        self.result = Assembly(2, 512)
        self.status = Assembly(46, 46)
        self.transaction = 0
        self.pending = None
        self.opcode = None
        self.capturing = False
        self.off = True
        self.snapshot = None
        self.sample_received = None
        self.updated = asyncio.Event()
        self.resubscribe = False

    async def subscribe(self):
        await self.client.start_notify(OFFLINE_RESULT, self.on_result)
        await self.client.start_notify(OFFLINE_PROGRESS, self.on_progress)

    def on_input(self, event):
        # An input edge may precede the producer's recording snapshot.
        active = bool(event.get('status', 0) & 3 or event['event'] == 1
                      or (event['event'] == 4 and event['capture'] == 2))
        self.off = event['capture'] == 0
        # OFF forbids audio transfer; idle snapshots must still let clock,
        # listing and durable-copy confirmation replies finish.
        if active or (self.off and self.opcode == 3):
            self.cancel()
        self.capturing = active
        self.updated.set()

    def cancel(self):
        self.result.clear()
        if self.pending and not self.pending.done():
            self.pending.set_exception(Preempted())

    def on_result(self, _characteristic, value):
        # Late replies for canceled transactions are ignored, including fragments.
        if not self.pending or self.pending.done():
            return
        try:
            if len(value) < 6 or struct.unpack_from('<H', value)[0] != self.transaction:
                return
            message = self.result.feed(bytes(value))
            if message:
                _, data = message
                if (data[0] != self.opcode or data[1] > 5
                        or (data[1] == 1 and data[0] != 2)
                        or (data[1] and len(data) != 2)):
                    raise ValueError('invalid offline reply opcode/status/length')
                if data[1]:
                    self.pending.set_exception(ReplyError(data[0], data[1]))
                else:
                    self.pending.set_result(data)
        except ValueError as exc:
            self.pending.set_exception(exc)
            self.resubscribe = True

    def on_progress(self, _characteristic, value):
        try:
            message = self.status.feed(bytes(value))
            if message:
                sequence, data = message
                if self.snapshot is not None:
                    distance = (sequence - self.snapshot['sequence']) & 0xffff
                    if distance == 0 or distance >= 0x8000:
                        return
                self.snapshot = progress(data, self.minor) | {'sequence': sequence}
                self.sample_received = time.monotonic()
                p = self.snapshot
                self.report(f"offline waiting={p['waiting']} free={p['free']}/{p['total']} "
                            f"flags=0x{p['flags']:02x} id={p['recording']} offset={p['offset']}")
                self.capturing = bool(p['flags'] & 3)
                if self.capturing:
                    self.cancel()
                self.updated.set()
        except ValueError as exc:
            self.report(f'offline progress rejected: {exc}')

    async def request(self, data):
        if self.pending and not self.pending.done():
            raise RuntimeError('one outstanding offline request required')
        if self.capturing or (data[0] == 3 and self.off):
            raise Preempted()
        if self.transaction == 65535:
            raise RuntimeError('offline transaction exhaustion: reconnect before wrap')
        if self.resubscribe:
            await self.client.stop_notify(OFFLINE_RESULT)
            await self.client.start_notify(OFFLINE_RESULT, self.on_result)
            self.resubscribe = False
        self.transaction += 1
        self.result.clear()
        self.opcode = data[0]
        self.pending = asyncio.get_running_loop().create_future()
        try:
            for value in fragments(data, self.transaction, self.budget, minimum=1):
                if self.pending.done():
                    return await self.pending  # capture stopped unsent request fragments
                await self.client.write_gatt_char(OFFLINE_CONTROL, value, response=True)
            return await asyncio.wait_for(self.pending, 5)
        except TimeoutError:
            self.resubscribe = True
            raise
        finally:
            if self.pending and not self.pending.done():
                self.pending.cancel()
            self.result.clear()

    async def set_clock(self):
        # G is sampled near receipt; do not extrapolate the remote tick into the future.
        if self.snapshot is None or time.monotonic() - self.sample_received > 5:
            self.snapshot = None
            self.status.clear()
            await self.client.stop_notify(OFFLINE_PROGRESS)
            await self.client.start_notify(OFFLINE_PROGRESS, self.on_progress)
            deadline = time.monotonic() + 5
            while self.snapshot is None:
                self.updated.clear()
                await asyncio.wait_for(self.updated.wait(), max(.001, deadline-time.monotonic()))
        p = self.snapshot
        elapsed = time.monotonic() - self.sample_received
        utc = int(time.time() * 1000 - elapsed * 1000)
        reply = await self.request(request_clock(p['boot'], p['tick'], utc))
        if reply != b'\x01\x00':
            raise ValueError('invalid clock acknowledgement')
        self.report(f"clock set boot={p['boot']} tick={p['tick']} approximate=true")


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def save_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    with temporary.open('w') as file:
        json.dump(value, file, sort_keys=True, indent=2)
        file.write('\n')
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)
    fsync_directory(path.parent)


class Copies:
    """Durable namespace by enrolled identity and ID, never by transfer date."""
    def __init__(self, directory, identity, maximum=512, decoder_factory=None):
        if not identity.strip():
            raise ValueError('--remote-id requires the enrolled identity')
        root = Path(directory)
        root.mkdir(parents=True, exist_ok=True)
        fsync_directory(root.parent)
        self.directory = root / hashlib.sha256(identity.encode()).hexdigest()
        self.directory.mkdir(exist_ok=True)
        fsync_directory(root)
        self.maximum, self.decoder_factory = maximum, decoder_factory
        identity_path = self.directory / 'identity.json'
        if identity_path.exists():
            if json.loads(identity_path.read_text()) != {'enrolled_identity': identity}:
                raise ValueError('enrolled identity namespace mismatch')
        else:
            save_json(identity_path, {'enrolled_identity': identity})

    def paths(self, meta):
        stem = self.directory / f'{meta.recording:020d}'
        return stem.with_suffix('.json'), stem.with_suffix('.partial'), stem.with_suffix('.stream')

    def prepare(self, meta):
        path, partial, stream = self.paths(meta)
        old = json.loads(path.read_text()) if path.exists() else None
        if old and old['metadata'] == asdict(meta):
            if old.get('durable'):
                self.verify(meta, stream)
                return meta.size
        else:
            if old and old.get('durable'):
                raise ValueError('durable ID metadata changed; check enrollment identity continuity')
            # Never splice bytes if an allegedly immutable record changed.
            partial.unlink(missing_ok=True)
            stream.unlink(missing_ok=True)
            save_json(path, {'metadata': asdict(meta), 'durable': False, 'confirmed': False})
        if stream.exists():
            # Crash after rename but before final durable marker; revalidate/redecode.
            stream.replace(partial)
            fsync_directory(self.directory)
        size = partial.stat().st_size if partial.exists() else 0
        if size > meta.size:
            partial.unlink()
            fsync_directory(self.directory)
            size = 0
        return size

    def append(self, meta, offset, data):
        _, partial, _ = self.paths(meta)
        with partial.open('a+b') as file:
            file.seek(0, os.SEEK_END)
            size = file.tell()
            if offset < size:
                file.seek(offset)
                if file.read(len(data)) != data:
                    raise ValueError('conflicting repeated offline bytes')
                return
            if offset != size or size + len(data) > meta.size:
                raise ValueError('offline copy gap/overflow')
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        fsync_directory(self.directory)

    def packets(self, file):
        while header := file.read(2):
            if len(header) != 2:
                raise ValueError('torn offline packet length')
            length = struct.unpack('<H', header)[0]
            if not 1 <= length <= self.maximum:
                raise ValueError('invalid offline packet length')
            data = file.read(length)
            if len(data) != length:
                raise ValueError('torn offline packet')
            yield header, data

    def verify(self, meta, path):
        size = count = crc = 0
        with path.open('rb') as file:
            for header, packet in self.packets(file):
                size += len(header) + len(packet)
                crc = zlib.crc32(header + packet, crc)
                count += 1
        if (size, count, crc) != (meta.size, meta.frames, meta.crc):
            raise ValueError('offline length/frame-count/CRC verification failed')

    def finish(self, meta):
        path, partial, stream = self.paths(meta)
        if partial.exists():
            self.verify(meta, partial)
            os.replace(partial, stream)
            fsync_directory(self.directory)
        self.verify(meta, stream)
        state = json.loads(path.read_text())
        if state.get('durable'):
            return state
        state['disposition'] = 'discarded-short' if meta.frames < 15 else 'audio-saved'
        if meta.frames >= 15:
            if self.decoder_factory is None:
                from opuslib_next import Decoder
                decoder = Decoder(16000, 1)
            else:
                decoder = self.decoder_factory()
            capture = (datetime.fromtimestamp(meta.utc / 1000, timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
                       if meta.utc else f'unknown-boot{meta.boot}-tick{meta.tick}')
            name = f"{meta.recording:020d}-{capture}-{'ai' if meta.mode else 'dictation'}.wav"
            destination = self.directory / name
            temporary = destination.with_suffix('.wav.tmp')
            try:
                with stream.open('rb') as source, temporary.open('wb') as file:
                    with wave.open(file, 'wb') as writer:
                        writer.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                        for _, packet in self.packets(source):
                            pcm = decoder.decode(packet, 320, False)
                            if len(pcm) != 640:
                                raise ValueError('offline Opus packet is not 20 ms mono PCM')
                            writer.writeframesraw(pcm)
                    file.flush()
                    os.fsync(file.fileno())
                os.replace(temporary, destination)
                fsync_directory(self.directory)
                state['wav'] = name
            except Exception as exc:
                state['error'] = str(exc)
                save_json(path, state)
                raise
        state.pop('error', None)
        state.update(durable=True, approximate_time=True, duration_ms=meta.frames * 20)
        save_json(path, state)
        return state

    def pending(self):
        for path in sorted(self.directory.glob('[0-9]*.json')):
            state = json.loads(path.read_text())
            if state.get('durable') and not state.get('confirmed'):
                meta = Metadata(**state['metadata'])
                self.verify(meta, self.paths(meta)[2])
                yield meta

    def confirmed(self, meta):
        path, _, _ = self.paths(meta)
        state = json.loads(path.read_text())
        if not state.get('durable'):
            raise ValueError('cannot confirm non-durable copy')
        state['confirmed'] = True
        save_json(path, state)


async def sync_pass(transport, copies, report=print):
    async def confirm(meta):
        reply = await transport.request(request_confirm(meta))
        if reply != b'\x04\x00':
            raise ValueError('invalid confirmation acknowledgement')
        copies.confirmed(meta)
        report(f'offline id={meta.recording} confirmed deletion; local durable copy retained')

    for meta in list(copies.pending()):
        await confirm(meta)  # Includes the lost-R4 / remote-already-deleted case.
    cursor = 0
    while True:
        try:
            reply = await transport.request(request_list(cursor))
        except ReplyError as exc:
            if exc.opcode == 2 and exc.status == 1:
                report('offline list exhausted')
                return
            raise
        if len(reply) != 44:
            raise ValueError('invalid list reply length')
        meta = Metadata.decode(reply[2:])
        if meta.recording <= cursor:
            raise ValueError('offline list did not advance')
        cursor = meta.recording
        offset = copies.prepare(meta)
        report(f'offline id={meta.recording} resume={offset}/{meta.size} frames={meta.frames}')
        while offset < meta.size:
            reply = await transport.request(request_fetch(meta.recording, offset))
            if len(reply) < 16:
                raise ValueError('short fetch reply')
            recording, received_offset, count = struct.unpack_from('<QIH', reply, 2)
            if (recording != meta.recording or received_offset != offset or not count
                    or count > 496 or len(reply) != count + 16 or offset + count > meta.size):
                raise ValueError('invalid fetch reply identity/offset/count')
            copies.append(meta, offset, reply[16:])
            offset += count
            report(f'offline id={meta.recording} durable={offset}/{meta.size} ({offset * 100 // meta.size}%)')
        state = copies.finish(meta)
        report(f"offline id={meta.recording} verified disposition={state['disposition']}")
        await confirm(meta)
