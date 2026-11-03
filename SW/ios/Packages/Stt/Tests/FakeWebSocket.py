"""Purpose: synthetic local RFC6455 server + bridge for Linux SttSocket tests.
Inputs: invented events and PCM values only. Verified by CloudTests; no vendor traffic.
No third-party dependencies, logs, recordings or credentials.
"""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
from urllib.parse import urlsplit, parse_qs


def exact(sock, count):
    result = b""
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise EOFError()
        result += chunk
    return result


def header(sock):
    result = b""
    while not result.endswith(b"\r\n\r\n"):
        result += exact(sock, 1)
    return result.decode()


def send(sock, opcode, data, masked=False):
    data = data.encode() if isinstance(data, str) else data
    length = len(data)
    extra = b"" if length < 126 else struct.pack("!H", length) if length < 65536 else struct.pack("!Q", length)
    size = length if length < 126 else 126 if length < 65536 else 127
    prefix = bytes([0x80 | opcode, size | (0x80 if masked else 0)]) + extra
    if masked:
        mask = os.urandom(4)
        data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
        prefix += mask
    sock.sendall(prefix + data)


def receive(sock, require_mask=False):
    first, second = exact(sock, 2)
    assert first & 0x80
    masked = bool(second & 0x80)
    assert masked or not require_mask
    count = second & 127
    if count == 126:
        count = struct.unpack("!H", exact(sock, 2))[0]
    if count == 127:
        count = struct.unpack("!Q", exact(sock, 8))[0]
    mask = exact(sock, 4) if masked else None
    data = exact(sock, count)
    if mask:
        data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
    return first & 15, data


def event(sock, obj):
    send(sock, 1, json.dumps(obj))


def server(vendor, scenario):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    print(listener.getsockname()[1], flush=True)
    sock, _ = listener.accept()
    sock.settimeout(5)
    request = header(sock)
    path = request.split(" ")[1]
    query = parse_qs(urlsplit(path).query)
    key = [line.split(": ", 1)[1] for line in request.split("\r\n") if line.lower().startswith("sec-websocket-key:")][0]
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
    try:
        if scenario == "signed":
            headers = dict(line.lower().split(": ", 1) for line in request.split("\r\n")[1:] if ": " in line)
            assert headers["x-relay-challenge"] == "synthetic-challenge"
            assert headers["x-relay-signature"] == "synthetic-signature"
        assert "key" not in request.lower().split("\r\n")[0] or "keyterms" in path
        if scenario == "malformed":
            send(sock, 1, "not json")
            return
        if scenario == "error":
            event(sock, {"message_type": "auth_error", "error": "synthetic"} if vendor == "elevenLabs" else {"type": "Error", "error": "synthetic"})
            return
        pcm = b""
        if vendor == "elevenLabs":
            assert query["model_id"] == ["scribe_v2_realtime"]
            assert query["audio_format"] == ["pcm_16000"]
            assert query["keyterms"] == ["Codex"]
            event(sock, {"message_type": "session_started"})
            if scenario == "informational":
                for kind in ["warning", "committed_transcript_with_timestamps", "committed_transcript_entities", "redacted_transcript", "edited_transcript"]:
                    event(sock, {"message_type": kind, "text": "must not become transcript"})
            while True:
                opcode, data = receive(sock, True)
                assert opcode == 1
                obj = json.loads(data)
                assert obj["message_type"] == "input_audio_chunk"
                pcm += base64.b64decode(obj["audio_base_64"])
                if obj["commit"]:
                    if scenario == "boundary":
                        assert len(pcm) == 640000 and not any(pcm)
                        event(sock, {"message_type": "committed_transcript", "text": "First segment."})
                        while sock.recv(1):
                            pass
                        return
                    if scenario == "segmented" and len(pcm) == 640000:
                        event(sock, {"message_type": "committed_transcript", "text": "First segment."})
                        continue
                    break
                event(sock, {"message_type": "partial_transcript", "text": "synthetic"})
            assert pcm == (bytes(640000) + bytes([0, 128, 255, 127]) if scenario == "segmented" else bytes([0, 128, 255, 127]))
            event(sock, {"message_type": "committed_transcript", "text": "Synthetic phrase."})
        else:
            assert query["speech_model"] == ["universal-3-5-pro"]
            assert json.loads(query["keyterms_prompt"][0]) == ["Codex"]
            event(sock, {"type": "Begin", "id": "synthetic"})
            if scenario == "informational":
                for kind in ["SpeechStarted", "Heartbeat", "SpeakerRevision", "LLMGatewayResponse"]:
                    event(sock, {"type": kind, "transcript": "must not become transcript"})
            while True:
                opcode, data = receive(sock, True)
                if opcode == 1:
                    assert json.loads(data) == {"type": "Terminate"}
                    break
                assert opcode == 2
                assert 1600 <= len(data) <= 32000 and len(data) % 2 == 0
                pcm += data
                event(sock, {"type": "Turn", "turn_order": 0, "end_of_turn": False, "transcript": "synthetic"})
            expected = bytes([0, 128, 255, 127])
            if scenario == "chunks":
                expected = bytes([1, 0]) * 16813
            assert pcm[:len(expected)] == expected
            assert not any(pcm[len(expected):])
            assert len(pcm) - len(expected) < 1600
            if scenario in ["partial_tail", "empty_tail"]:
                event(sock, {"type": "Turn", "turn_order": 0, "end_of_turn": False, "transcript": "unfinished synthetic text"})
                if scenario == "empty_tail":
                    event(sock, {"type": "Turn", "turn_order": 0, "end_of_turn": True, "transcript": ""})
                event(sock, {"type": "Termination"})
                return
            for _ in range(2):
                event(sock, {"type": "Turn", "turn_order": 0, "end_of_turn": True, "turn_is_formatted": True, "transcript": "Synthetic phrase."})
            event(sock, {"type": "Turn", "turn_order": 1, "end_of_turn": True, "transcript": "Second segment."})
            event(sock, {"type": "Termination"})
    except Exception:
        event(sock, {"type": "Error", "message_type": "error"})
    finally:
        sock.close()
        listener.close()


def bridge(url):
    import threading
    parts = urlsplit(url)
    sock = socket.create_connection((parts.hostname, parts.port), timeout=5)
    sock.settimeout(None)
    key = base64.b64encode(os.urandom(16)).decode()
    proof = json.loads(base64.b64decode(sys.argv[3])) if len(sys.argv) > 3 else {}
    extra = "".join(f"{name}: {value}\r\n" for name, value in proof.items())
    sock.sendall((f"GET {parts.path}?{parts.query} HTTP/1.1\r\nHost: {parts.hostname}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n{extra}\r\n").encode())
    response = header(sock)
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    assert "101 Switching" in response and accept in response
    def outgoing():
        try:
            for line in sys.stdin:
                obj = json.loads(line)
                send(sock, 1 if "text" in obj else 2, obj.get("text") if "text" in obj else base64.b64decode(obj["binary"]), True)
        except (OSError, ValueError):
            pass
    threading.Thread(target=outgoing, daemon=True).start()
    try:
        while True:
            opcode, data = receive(sock)
            if opcode == 8:
                break
            print(json.dumps({"text": data.decode()} if opcode == 1 else {"binary": base64.b64encode(data).decode()}), flush=True)
    except (EOFError, OSError):
        pass
    finally:
        sock.close()


if sys.argv[1] == "server":
    server(sys.argv[2], sys.argv[3])
else:
    bridge(sys.argv[2])
