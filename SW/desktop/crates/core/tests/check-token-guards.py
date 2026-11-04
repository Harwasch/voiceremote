#!/usr/bin/env python3
"""Purpose: prove used/expired-token regressions detect removed guards.
Inputs: src/pairing.rs and tests/security.rs; synthetic live peers only.
Verified by baseline passes and runtime test failures for each temporary mutation.
Run manually with no concurrent desktop build. Always restores source contents.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess

core = Path(__file__).resolve().parents[1]
source = core / 'src/pairing.rs'
manifest = core.parents[1] / 'Cargo.toml'
original = source.read_text()
cases = [
    ('used-token', 'wrong_confirmation_never_enrolls_and_consumes_token',
     original.replace('ensure!(!self.used, "enrollment token already used");', '')),
    ('expiry', 'expired_token_rejected_before_handshake',
     re.sub(r'    ensure!\(\n        remaining > 0 && remaining <= TOKEN_TTL_MS,\n'
            r'        "expired or far-future enrollment"\n    \);', '', original)),
]
env = {**os.environ, 'HEAVY_CPUS': '4', 'RUST_TEST_THREADS': '4'}


def run(test):
    command = ['cargo', 'test', '-p', 'voiceremote-core', '--manifest-path',
               str(manifest), '-j4', '--test', 'security', test, '--', '--exact']
    if shutil.which('heavy'):
        command.insert(0, 'heavy')
    return subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)


try:
    for label, test, mutated in cases:
        assert mutated != original, f'{label}: guard source changed; review mutation'
        source.write_text(original)
        baseline = run(test)
        assert baseline.returncode == 0, baseline.stdout
        source.write_text(mutated)
        result = run(test)
        assert result.returncode != 0 and 'test result: FAILED.' in result.stdout, result.stdout
        print(f'{label}: baseline PASS; removed guard detected by runtime test (exit {result.returncode})')
finally:
    source.write_text(original)
print('Original source restored; run normal checks before review.')
