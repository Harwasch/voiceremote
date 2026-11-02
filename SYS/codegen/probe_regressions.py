#!/usr/bin/env python3
"""Purpose: prove every new control/duplicate fixture detects its removed rule.

Inputs: generated TS codec, source dictation schema and shared golden vectors.
Verified by running this script, then `make -C SYS check` after restoration.
Only the generated TS file is temporarily changed; it is restored in finally.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    path = ROOT / 'SW/relay/src/protocol/generated.ts'
    original = path.read_bytes()
    text = original.decode()
    vectors = json.loads((ROOT / 'SYS/protocol/vectors/golden.json').read_text())
    schema = json.loads((ROOT / 'SYS/protocol/protocol.schema.json').read_text())
    control_rule = schema['$defs']['DictationText']['properties']['text']['not']
    probes = [
        ('dictation controls', ',"not":' + json.dumps(control_rule, separators=(',', ':')), '',
         'rejects dictation control',
         {'rejects ' + v['name'] for v in vectors['invalid'] if v['name'].startswith('dictation control ')}),
        ('duplicate keys', 'if (keys.has(key)) throw new Error("Duplicate JSON key");', '',
         'rejects raw duplicate',
         {'rejects raw ' + v['name'] for v in vectors['raw_invalid'] if v['name'].startswith('duplicate ')}),
    ]
    try:
        for name, needle, replacement, selector, expected in probes:
            if text.count(needle) != 1 or not expected:
                raise RuntimeError(f'{name}: mutation/fixture selection is not unique')
            path.write_text(text.replace(needle, replacement))
            with tempfile.TemporaryDirectory(prefix='voiceremote-regression-') as directory:
                report = Path(directory) / 'vitest.json'
                result = subprocess.run(
                    ['heavy', 'npx', '--no-install', 'vitest', 'run', '--maxWorkers=4',
                     '--reporter=json', '--outputFile', str(report), '--testNamePattern', selector],
                    cwd=ROOT / 'SW/relay', env={**os.environ, 'HEAVY_CPUS': '4'},
                    text=True, capture_output=True,
                )
                if not report.exists():
                    raise RuntimeError(result.stdout + result.stderr)
                data = json.loads(report.read_text())
                failed = {case['title'] for suite in data['testResults']
                          for case in suite['assertionResults'] if case['status'] == 'failed'}
                if result.returncode == 0 or failed != expected:
                    raise RuntimeError(f'{name}: missing failures {expected - failed}, unexpected {failed - expected}')
                print(f'{name}: {len(expected)}/{len(expected)} new vectors failed with rule removed (expected)')
    finally:
        path.write_bytes(original)
    print('Generated TS codec restored byte-for-byte; run make -C SYS check.')


if __name__ == '__main__':
    main()
