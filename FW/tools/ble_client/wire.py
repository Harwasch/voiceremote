"""Contract v1 controls and bench arm recovery; synthetic labels only."""
import struct
import unicodedata

SERVICE = "f934bb04-9472-4805-8ea8-11f9f5bcabbc"
INFO = "cba8d4dd-2aea-4964-a0b7-ef58095a1171"
INPUT = "9f0f839c-fe73-46e4-acc3-53518ed5689c"
PHONE = "d9306a59-9e64-48c5-8722-827a0592a412"
AUDIO = "6df454c4-b29c-4638-b4f5-cc43e81e2427"

def text(value: str, maximum: int, empty: bool = False) -> bytes:
    data = value.encode("utf-8")
    if any(unicodedata.category(c) == "Cc" for c in value):
        raise ValueError("control characters are forbidden")
    if len(data) > maximum or (not data and not empty):
        raise ValueError(f"text must fit {maximum} UTF-8 bytes")
    return bytes([len(data)]) + data


def phone_state(ack: int, *, target: str = "PC", link: str = "BLE", error: str = "",
                capture: int = 0, recording: int = 0, mode: int = 0, arm: bool = False,
                snapshot: bool = True) -> bytes:
    if capture not in range(3) or recording not in range(4) or mode not in range(2):
        raise ValueError("invalid state enum")
    if (capture == 0 and (recording == 1 or arm)) or (arm and recording != 1):
        raise ValueError("invalid off/recording/arm combination")
    flags = int(snapshot) | (int(arm) << 1)
    data = struct.pack("<6BI", flags, capture, recording, mode, 2, 0, ack)
    data += text("Auto", 32) + text(target, 32) + text(target, 32)
    data += text(link, 48, True) + text(error, 64, True)
    if not 19 <= len(data) <= 512:
        raise ValueError("state length outside contract")
    return data


def fragments(data: bytes, transaction: int, budget: int):
    if not 19 <= len(data) <= 512 or not 7 <= budget <= 512:
        raise ValueError("invalid state length or write budget")
    for offset in range(0, len(data), budget - 6):
        yield struct.pack("<HHH", transaction, len(data), offset) + data[offset:offset + budget - 6]


def input_event(data: bytes) -> dict:
    if len(data) != 14:
        raise ValueError("Input must be 14 bytes")
    seq, ms, event, capture, mode, ptt, streaming, reserved = struct.unpack("<II6B", data)
    if (event > 5 or capture > 2 or mode > 1 or ptt > 1 or streaming > 1 or reserved
            or (event == 1 and ptt != 1) or (event == 2 and ptt != 0)
            or (capture == 0 and streaming)):
        raise ValueError("malformed Input")
    return dict(seq=seq, ms=ms, event=event, capture=capture, mode=mode, ptt=ptt, streaming=streaming)


def version_info(data: bytes) -> dict:
    if len(data) != 20:
        raise ValueError("Version/info must be 20 bytes")
    major, minor, board, a, b, c, reserved, caps, mics, slider, w, h, maximum, tail = struct.unpack("<BBH4BHBB4H", data)
    if ((major, minor) != (1, 0) or reserved or tail or caps & ~127 or not mics
            or slider > 1 or board not in (1, 2, 65535) or not 1 <= maximum <= 4096
            or (bool(w) and bool(h)) != bool(caps & 2) or (not caps & 2 and (w or h))):
        raise ValueError("unsupported/malformed Version/info")
    return dict(contract=f"{major}.{minor}", board=board, firmware=f"{a}.{b}.{c}",
                capabilities=caps, mics=mics, slider=slider, width=w, height=h,
                maximum_packet=maximum, full_v1_capabilities=(caps & 63 == 63))


class BenchPolicy:
    """Bench-only arm intent, with contract loss/reconnect trigger recovery."""
    def __init__(self, arm=False):
        self.intent = arm
        self.latest = None
        self.snapshot_needed = True
        self.blocked = False
        self.released = False
        self.rec_selected = False
        self.ptt_selected = False

    def lose(self):
        self.blocked = True
        self.snapshot_needed = True
        self.released = False
        self.rec_selected = False
        self.ptt_selected = False

    def input(self, event):
        previous = self.latest
        if previous:
            distance = (event['seq'] - previous['seq']) & 0xffffffff
            if distance == 0 or distance >= 0x80000000:
                return False, False
            loss = distance != 1
            kind = event['event']
            if not loss:
                expected = dict(previous)
                if kind in (1, 2):
                    expected['ptt'] = kind == 1
                    loss = previous['ptt'] == expected['ptt']
                elif kind == 4:
                    expected['capture'] = event['capture']
                    loss = previous['capture'] == event['capture']
                elif kind == 5:
                    expected['mode'] = event['mode']
                    loss = previous['mode'] == event['mode']
                loss |= any(event[k] != expected[k] for k in ('ptt', 'capture', 'mode'))
            if loss:
                self.lose()
        else:
            loss = False
        self.latest = event
        if event['event'] == 0:
            self.snapshot_needed = False
        if not event['ptt']:
            self.released = True
            self.ptt_selected = False
        if not self.snapshot_needed:
            if event['event'] == 1 and self.released:
                self.blocked = False
                self.released = False
                self.ptt_selected = True
            if event['event'] == 4 and event['capture'] == 2 and not loss:
                self.blocked = False
                self.rec_selected = True
        if event['capture'] != 2:
            self.rec_selected = False
        return True, loss

    def arm(self):
        e = self.latest
        return bool(self.intent and e and not self.blocked and not self.snapshot_needed
                    and e['capture'] != 0
                    and ((e['capture'] == 1 and (self.released or self.ptt_selected))
                         or (e['capture'] == 2 and self.rec_selected)))

    def streaming_allowed(self):
        e = self.latest
        return bool(self.arm() and e and (e['capture'] != 1 or e['ptt']))
