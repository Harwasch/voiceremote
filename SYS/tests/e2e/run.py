"""Purpose: coordinate real clients; never implements or fakes a wire endpoint.
Inputs: local production Worker and compiled Rust/Swift binaries. run.sh verifies.
QRs and keys stay in memory or private temporary storage, never in output.
"""
import json
import os
from pathlib import Path
import queue
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[3]
def terminate(signum, frame): raise SystemExit(128 + signum)
signal.signal(signal.SIGTERM, terminate)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})

class Child:
    def __init__(self, args):
        environment = os.environ.copy()
        for name in ['VOICEREMOTE_RELAY_URL', 'VOICEREMOTE_ACCOUNT', 'VOICEREMOTE_RELAY_BOOTSTRAP_SECRET']:
            environment.pop(name, None)
        self.process = subprocess.Popen(args, cwd=ROOT, env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.events = queue.Queue()
        self.insertions = 0
        for label, stream in [('out', self.process.stdout), ('err', self.process.stderr)]:
            def read(stream=stream, label=label):
                for line in stream:
                    if line.rstrip() == 'E2E_INSERTED': self.insertions += 1
                    self.events.put((label, line.rstrip()))
                self.events.put((label, None))
            threading.Thread(target=read, daemon=True).start()
    def wait_line(self, predicate, seconds=35):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try: label, line = self.events.get(timeout=max(.01, deadline-time.monotonic()))
            except queue.Empty: break
            if line is not None and predicate(label, line): return line
            if self.process.poll() is not None and self.events.empty():
                raise RuntimeError(f'child exited ({self.process.returncode}); payload omitted')
        raise RuntimeError('timed out waiting for client event; payload omitted')
    def send(self, line):
        self.process.stdin.write(line + '\n'); self.process.stdin.flush()
    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
    def success(self):
        if self.process.wait(timeout=10) != 0: raise RuntimeError('endpoint exited unsuccessfully')

def queued_frames(storage, target):
    for path in storage.rglob('*.sqlite'):
        try:
            with sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=.1) as db:
                if db.execute("SELECT count(*) FROM sqlite_master WHERE name='frames'").fetchone()[0]:
                    return db.execute('SELECT count(*) FROM frames WHERE target=?', (target,)).fetchone()[0]
        except sqlite3.Error: pass
    return 0

children = []
try:
    with tempfile.TemporaryDirectory(prefix='voiceremote-e2e-') as temp:
        relay = Child(['node', 'SYS/tests/e2e/relay.mjs', temp]); children.append(relay)
        origin = relay.wait_line(lambda label, line: label == 'out' and line.startswith('http://127.0.0.1:'))
        swift = ROOT / 'SW/ios/Packages/Pairing/.build/debug/phone-e2e'
        desktop = ROOT / 'SW/desktop/target/debug/voiceremote'
        for mode in ['relay', 'lan']:
            args = [str(desktop), '--state-dir', str(Path(temp)/mode), '--e2e-injector',
                    'pair', '--code', '--account', 'synthetic-e2e', '--device', 'desktop']
            args += ['--relay', origin] if mode == 'relay' else ['--listen', '127.0.0.1:0']
            receiver = Child(args); children.append(receiver)
            # LAN endpoint is emitted on stderr before the QR. Retain it while
            # draining both pipes, never print the QR/token or phrase.
            port = None; qr = None
            deadline = time.monotonic() + 30
            while qr is None or (mode == 'lan' and port is None):
                label, line = receiver.events.get(timeout=max(.01, deadline-time.monotonic()))
                if line and line.startswith('LAN pairing listener: '):
                    port = line.split()[3].rsplit(':', 1)[1]
                if label == 'out' and line and line.startswith('{'): qr = json.loads(line)
                if receiver.process.poll() is not None: raise RuntimeError('desktop pairing failed; payload omitted')
            phone = Child([str(swift), mode, origin if mode == 'relay' else port]); children.append(phone)
            phone.send(json.dumps(qr, separators=(',', ':')))
            phrase = phone.wait_line(lambda label, line: label == 'out' and line.startswith('PHRASE:')).split(':', 1)[1]
            desktop_phrase = receiver.wait_line(lambda label, line: label == 'err' and line.startswith('Compare on both devices: ')).split(': ', 1)[1]
            if phrase != desktop_phrase: raise RuntimeError('phrase mismatch')
            receiver.send(phrase); phone.send('confirm')
            phone.wait_line(lambda label, line: line == 'PAIRED')
            receiver.wait_line(lambda label, line: line.startswith('Paired phone ('))
            phone.send('dictate')
            receiver.wait_line(lambda label, line: line == 'E2E_INSERTED')
            phone.wait_line(lambda label, line: line == 'SENT')
            if mode == 'relay':
                receiver.close()
                if receiver.insertions != 1: raise RuntimeError('unexpected initial insertion count')
                phone.send('queue')
                phone.wait_line(lambda label, line: line == 'QUEUED_OLD_SESSION')
                deadline = time.monotonic() + 10
                storage = Path(temp) / 'relay-storage'
                while queued_frames(storage, 'desktop') == 0:
                    if time.monotonic() > deadline: raise RuntimeError('old-session frame was not persisted by actual Worker')
                    time.sleep(.05)
                    phone.send('queue')
                    phone.wait_line(lambda label, line: line == 'QUEUED_OLD_SESSION')
                receiver = Child([str(desktop), '--state-dir', str(Path(temp)/mode), '--e2e-injector',
                                  'run', '--headless', '--account', 'synthetic-e2e', '--relay', origin])
                children.append(receiver)
            phone.send('resume')
            receiver.wait_line(lambda label, line: line == 'E2E_INSERTED')
            phone.wait_line(lambda label, line: line == 'RESUMED')
            phone.send('revoke')
            phone.wait_line(lambda label, line: line == 'REVOKED_NEXT_MESSAGE_REJECTED')
            phone.success(); receiver.success()
            if receiver.insertions != (1 if mode == 'relay' else 2): raise RuntimeError('unexpected insertion count after resume')
            if mode == 'relay' and queued_frames(storage, 'desktop') != 0: raise RuntimeError('replayed queue not drained')
            print(f'PASS {mode}: XX, phrase, dictation, resume, revoke, next-message rejection' + ('; real room create/redeem, persisted stale queue, permanent 403' if mode == 'relay' else ''), flush=True)
        cloud = Child(['node', 'SYS/tests/e2e/relay.mjs', str(Path(temp)/'cloud'), 'proxy']); children.append(cloud)
        cloud_origin = cloud.wait_line(lambda label, line: label == 'out' and line.startswith('http://127.0.0.1:'))
        invitation = cloud.wait_line(lambda label, line: label == 'out' and line.startswith('PROXY_INVITE:')).split(':', 1)[1]
        proxy = Child([str(ROOT/'SYS/tests/e2e/.build/debug/proxy-e2e'), cloud_origin]); children.append(proxy)
        proxy.send(invitation)
        passed = proxy.wait_line(lambda label, line: label == 'out' and line.startswith('PASS proxy:'), seconds=60)
        proxy.success(); print(passed, flush=True)

finally:
    for child in reversed(children): child.close()
