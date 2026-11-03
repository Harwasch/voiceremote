"""Bounded contract reassembly and per-segment WAV output. No PLC or splicing."""
from dataclasses import dataclass
from pathlib import Path
import struct
import time
import wave


class AudioLoss(ValueError):
    pass


@dataclass
class AudioEvent:
    segment: int
    frame: int
    packet: bytes | None  # None is END


class Reassembler:
    def __init__(self, maximum=512):
        self.maximum = maximum
        self.segment = None
        self.last_segment = 0
        self.next_frame = 0
        self.partial = bytearray()
        self.total = 0
        self.previous = None
        self.last_activity = None

    def reset(self):
        self.segment = None
        self.next_frame = 0
        self.partial.clear()
        self.total = 0
        self.previous = None
        self.last_activity = None

    def feed(self, value: bytes) -> AudioEvent | None:
        if len(value) < 12:
            raise AudioLoss("short Audio header")
        segment, frame, flags, reserved, offset, total = struct.unpack_from("<IHBBHH", value)
        payload = value[12:]
        if not segment or reserved or flags & ~7:
            raise AudioLoss("invalid Audio header")
        end = bool(flags & 2)
        if end:
            if flags != 6 or not frame or offset or total or payload:
                raise AudioLoss("invalid END")
        elif (not payload or not 0 < total <= self.maximum or offset >= total
              or offset + len(payload) > total or frame == 65535
              or bool(flags & 1) != (frame == 0)
              or bool(flags & 4) != (offset + len(payload) == total)):
            raise AudioLoss("invalid fragment / START / LAST")
        if self.segment is not None and segment < self.segment:
            return None  # completed older segment while a newer one is active
        if self.segment is None:
            if segment <= self.last_segment:
                return None  # stale completed/interrupted segment; never decode twice
            expected = self.last_segment + 1
            self.last_segment = segment
            if segment != expected:
                raise AudioLoss(f"segment gap: expected {expected}, got {segment}")
            if end or frame or offset or not flags & 1:
                raise AudioLoss("segment did not begin with START at offset 0")
            self.segment = segment
        if segment != self.segment:
            self.last_segment = max(self.last_segment, segment)
            raise AudioLoss("unexpected segment before END")
        if frame < self.next_frame:
            if self.previous and frame == self.previous[0]:
                packet = self.previous[1]
                if end or total != len(packet) or packet[offset:offset + len(payload)] != payload:
                    raise AudioLoss("conflicting duplicate completed packet")
            return None
        if frame != self.next_frame:
            raise AudioLoss(f"frame gap: expected {self.next_frame}, got {frame}")
        if end:
            if self.partial:
                raise AudioLoss("END interrupted a fragmented packet")
            result = AudioEvent(segment, frame, None)
            self.reset()
            return result
        if self.partial and total != self.total:
            raise AudioLoss("conflicting packet total")
        if offset < len(self.partial):
            if offset + len(payload) <= len(self.partial) and self.partial[offset:offset + len(payload)] == payload:
                return None
            raise AudioLoss("conflicting duplicate fragment")
        if offset != len(self.partial):
            raise AudioLoss("fragment gap")
        self.total = total
        self.last_activity = time.monotonic()
        self.partial.extend(payload)
        if flags & 4:
            packet = bytes(self.partial)
            self.previous = (frame, packet)
            self.partial.clear()
            self.next_frame += 1
            return AudioEvent(segment, frame, packet)
        return None

    def watchdog(self, now=None):
        if self.last_activity is not None and (time.monotonic() if now is None else now) - self.last_activity >= 1:
            raise AudioLoss("Audio watchdog: 1000 ms without a complete stream")


class WavRecorder:
    def __init__(self, path, maximum=512, mtu=23, decoder_factory=None, report=print):
        if decoder_factory is None:
            try:
                from opuslib_next import Decoder
                # Fail before Bluetooth access when system libopus is unavailable.
                Decoder(16000, 1)
            except Exception as exc:
                raise RuntimeError("Opus decoding needs opuslib-next and system libopus.so.0; install libopus0") from exc
            decoder_factory = lambda: Decoder(16000, 1)
        self.expected_at = None
        self.decoder_factory = decoder_factory
        self.path = Path(path) if path else None
        if self.path:
            if self.path.suffix.lower() != '.wav':
                raise ValueError('--save must end in .wav')
            if not self.path.parent.is_dir():
                raise ValueError('--save parent directory must exist')
        self.reassembly = Reassembler(maximum)
        self.mtu = mtu
        self.report = report
        self.writer = None
        self.file = None
        self.segment = None
        self.decoder = None
        self.frames = self.gaps = self.bytes = self.wire_bytes = 0
        self.filename = None
        self.mtu_lower_bound = 23
        self.last_frame = -1

    def expect_streaming(self, streaming):
        if not streaming:
            self.expected_at = None
        elif self.reassembly.segment is None and self.expected_at is None:
            self.expected_at = time.monotonic()

    def watchdog(self, now=None):
        now = time.monotonic() if now is None else now
        self.reassembly.watchdog(now)
        if self.expected_at is not None and now - self.expected_at >= 1:
            raise AudioLoss('Audio watchdog: streaming Input but no START in 1000 ms')

    def _start(self, segment):
        self.segment = segment
        self.decoder = self.decoder_factory()
        self.frames = self.gaps = self.bytes = self.wire_bytes = 0
        self.mtu_lower_bound = 23
        self.last_frame = -1
        if self.path:
            self.filename = self.path.with_name(f"{self.path.stem}-seg{segment:08d}.wav")
            self.file = self.filename.open("xb")
            self.writer = wave.open(self.file, "wb")
            self.writer.setparams((1, 2, 16000, 0, "NONE", "not compressed"))

    def feed(self, value):
        event = self.reassembly.feed(bytes(value))
        if self.segment is None and self.reassembly.segment is not None:
            self._start(self.reassembly.segment)
        if self.segment is not None:
            self.expected_at = None
            self.wire_bytes += len(value)
            self.mtu_lower_bound = max(self.mtu_lower_bound, len(value) + 3)
        if event is None:
            return
        if event.packet is None:
            self.close()
            return
        pcm = self.decoder.decode(event.packet, 320, False)
        if len(pcm) != 640:
            raise AudioLoss("Opus packet does not decode to 320 mono Int16 samples")
        if self.writer:
            self.writer.writeframesraw(pcm)
        self.frames += 1
        self.last_frame = event.frame
        self.bytes += len(event.packet)

    def close(self, interrupted=False, reason="END"):
        if self.segment is not None:
            self.gaps += int(interrupted)
            if self.writer:
                self.writer.close()
                self.file.close()
                if interrupted:
                    destination = self.filename.with_stem(self.filename.stem + "-interrupted")
                    if destination.exists():
                        raise FileExistsError(destination)
                    self.filename.rename(destination)
                    self.filename = destination
            duration = self.frames * .02
            self.report(f"segment={self.segment} frames={self.frames} gaps={self.gaps} "
                        f"opus_Bps={self.bytes / duration if duration else 0:.1f} "
                        f"wire_Bps={self.wire_bytes / duration if duration else 0:.1f} "
                        f"public_MTU={self.mtu} audio_MTU_at_least={self.mtu_lower_bound} duration={duration:.3f}s "
                        f"status={'interrupted' if interrupted else 'complete'} reason={reason} "
                        f"wav={self.filename or 'disabled'}")
        self.writer = self.file = self.decoder = self.segment = None
        self.expected_at = None
        self.reassembly.reset()
