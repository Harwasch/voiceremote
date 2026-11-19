"""Purpose: reproduce UI3 timing evidence without copying synthetic element trees.
Inputs: coordinator's complete ui3.log. Verified: local parser on UI3 only.
Usage: python3 THIS_FILE PATH_TO_UI3_LOG
"""
import json
from pathlib import Path
import re
import sys

lines = Path(sys.argv[1]).read_text().splitlines()
tests, gaps, previous = [], [], None
for line in lines:
    match = re.search(r"Test Case.* (test\w+)\]' (passed|failed) \(([\d.]+) seconds\)", line)
    if match:
        tests.append({'test': match[1], 'outcome': match[2], 'seconds': float(match[3])})
    if "Test Case" in line and "started" in line:
        previous = None
    event = re.search(r't =\s+([\d.]+)s\s+(.*)', line)
    if event:
        current = float(event[1]), event[2]
        if previous and current[0] - previous[0] > 2:
            gaps.append({'seconds': round(current[0] - previous[0], 2), 'after': previous[1]})
        previous = current
print(json.dumps({'completed_tests': tests, 'longest_event_gaps': sorted(gaps, key=lambda v: -v['seconds'])[:8],
    'event_counts': {token: sum(token in line for line in lines) for token in [
        'Requesting snapshot', 'Checking existence', 'Press', 'Added attachment', 'Waiting 2.0s', 'Wait for com.harwasch']}}, indent=2))
