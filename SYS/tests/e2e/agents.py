"""Purpose: real phone/Policy/Router/paired relay/agent process integration.
Inputs: production binaries and Worker, synthetic provider executables below.
Verified only when run.py prints both PASS agents results; no live provider claim.
"""
import json
import os
from pathlib import Path
import time


def run_agents(Child, root, origin, temp, children):
    base = Path(temp) / 'agents'
    base.mkdir()
    binaries = base / 'bin'
    binaries.mkdir()
    scopes = base / 'scopes'
    scopes.mkdir()
    # No owner CLI or credential store is touched. Markers contain no payload.
    cli = r'''#!/usr/bin/python3
import sys, os, json, time, subprocess
args=sys.argv[1:]
text=sys.stdin.read()
with open('called', 'a') as f: f.write('invoked\n')
if text == 'wait-tree':
    child=subprocess.Popen(['/usr/bin/python3','-c','import time; time.sleep(60)'], start_new_session=True)
    with open('child.pid','w') as f: f.write(str(child.pid))
    while True: time.sleep(1)
if '--resume' in args:
    session=args[args.index('--resume')+1]
    print(json.dumps({'type':'result','subtype':'success','is_error':False,'session_id':session}))
else:
    print(json.dumps({'type':'thread.started','thread_id':args[-2]}))
    print(json.dumps({'type':'turn.completed'}))
'''
    systemd = r'''#!/usr/bin/python3
import os,sys,json
from pathlib import Path
args=sys.argv[1:]
unit=args[args.index('--unit')+1]
root=Path(__file__).resolve().parent.parent
workspace=Path.cwd()
with open(root/'scopes'/unit,'w') as f: json.dump({'pid':os.getpid(),'workspace':str(workspace)},f)
argv=args[args.index('--')+1:]
os.execvp(argv[0],argv)
'''
    control = r'''#!/usr/bin/python3
import sys,os,json,signal
from pathlib import Path
args=sys.argv[1:]
if '--property=Version' in args: print('synthetic'); sys.exit(0)
root=Path(__file__).resolve().parent.parent
path=root/'scopes'/args[-1]
if 'kill' in args or 'stop' in args:
    try:
        state=json.loads(path.read_text())
        child=Path(state['workspace'])/'child.pid'
        pids=[state['pid']]+([int(child.read_text())] if child.exists() else [])
        for pid in pids:
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
    except FileNotFoundError: pass
if '--property=ActiveState' in args: print('ActiveState=inactive\nTasksCurrent=0\nLoadState=loaded')
'''
    for name, body in [('claude', cli), ('codex', cli), ('systemd-run', systemd), ('systemctl', control)]:
        file = binaries / name
        file.write_text(body)
        file.chmod(0o700)
    desktop = root / 'SW/desktop/target/debug/voiceremote'
    swift = root / 'SYS/tests/e2e/.build/debug/proxy-e2e'
    for deny in [True, False]:
        case = base / ('denied' if deny else 'allowed')
        case.mkdir()
        for provider in ['claude', 'codex']:
            (case / provider).mkdir()
        config = case / 'agents.toml'
        config.write_text('account="synthetic-e2e"\nhost="desktop"\nphone_device="phone"\nactor="phone"\ntimeout_ms=20000\n' + ''.join(
            f'\n[[projects]]\nproject="arm-{provider}"\nworkspace={json.dumps(str(case/provider))}\nprovider="{provider}"\naccount="synthetic-e2e"\nhost="desktop"\nsessions=["test-{provider}"]\n'
            for provider in ['claude', 'codex']))
        config.chmod(0o600)
        environment = {'PATH': str(binaries) + ':/usr/bin:/bin'}
        def node():
            child = Child([str(desktop), '--state-dir', str(case/'state'), 'run', '--headless',
                           '--account', 'synthetic-e2e', '--agents-config', str(config), '--relay', origin], environment)
            children.append(child)
            return child
        receiver = Child([str(desktop), '--state-dir', str(case/'state'), 'pair', '--code', '--allow-agents',
                          '--account', 'synthetic-e2e', '--device', 'desktop', '--relay', origin], environment)
        children.append(receiver)
        qr = receiver.wait_line(lambda label, line: label == 'out' and line.startswith('{'))
        phone = Child([str(swift), 'agents', origin, 'deny' if deny else 'allow'])
        children.append(phone)
        phone.send(qr)
        phrase = phone.wait_line(lambda label, line: line.startswith('PHRASE:')).split(':', 1)[1]
        desktop_phrase = receiver.wait_line(lambda label, line: line.startswith('Compare on both devices: ')).split(': ', 1)[1]
        if phrase != desktop_phrase: raise RuntimeError('agent phrase mismatch')
        receiver.send(phrase)
        phone.send('confirm')
        phone.wait_line(lambda label, line: line == 'PAIRED')
        receiver.wait_line(lambda label, line: line.startswith('Paired phone ('))
        receiver.close()
        receiver = node()
        phone.send('resume')
        if deny:
            passed = phone.wait_line(lambda label, line: line.startswith('PASS agents denied:'))
            phone.success()
            if any(case.rglob('called')): raise RuntimeError('capability-free phone launched a process')
            print(passed, flush=True)
        else:
            phone.wait_line(lambda label, line: line == 'AGENT_NAMED_SESSION_SUCCEEDED')
            phone.wait_line(lambda label, line: line == 'AGENT_OFFLINE_READY')
            receiver.close()
            phone.send('offline')
            phone.wait_line(lambda label, line: line == 'AGENT_HELD_OFFLINE')
            receiver = node()
            phone.send('resume')
            phone.wait_line(lambda label, line: line == 'AGENT_HELD_RELEASED')
            phone.wait_line(lambda label, line: line == 'AGENT_CANCEL_READY')
            child_file = case/'claude'/'child.pid'
            deadline = time.monotonic() + 10
            while not child_file.exists():
                if time.monotonic() >= deadline: raise RuntimeError('fake provider did not start descendant')
                time.sleep(.02)
            pid = int(child_file.read_text())
            phone.send('cancel')
            phone.wait_line(lambda label, line: line == 'AGENT_CANCELLED')
            # A zombie is already dead; PID existence alone does not mean running.
            stat = Path(f'/proc/{pid}/stat')
            if stat.exists() and stat.read_text().split()[2] != 'Z': raise RuntimeError('cancel left descendant running')
            passed = phone.wait_line(lambda label, line: line.startswith('PASS agents:'))
            phone.success()
            if len((case/'claude'/'called').read_text().splitlines()) != 2 or len((case/'codex'/'called').read_text().splitlines()) != 1:
                raise RuntimeError('agent delivery ran more than once or injected authority launched work')
            print(passed, flush=True)
        receiver.close()
