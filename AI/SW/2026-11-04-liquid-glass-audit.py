"""Purpose: reproduce screenshot audit triage counts without copying element trees.
Inputs: synthetic audit__*.json exports. Verified: first-run 73-audit inventory only.
Usage: python3 THIS_FILE PATH_TO_EXPORTED_GALLERY
"""
import collections
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
counts = collections.Counter()
labels = collections.defaultdict(collections.Counter)
files = list(root.glob('audit__*.json'))
for path in files:
    for finding in json.loads(path.read_text()).get('findings', []):
        summary = finding['summary']
        counts[summary] += 1
        first_line = finding.get('element', 'unavailable').split('\n')[0]
        match = re.search(r"(?:identifier|label): '([^']*)'", first_line)
        labels[summary][match.group(1) if match else 'unavailable'] += 1
print(json.dumps({'audits': len(files), 'findings': sum(counts.values()), 'counts': dict(counts),
                  'common_elements': {k: v.most_common(12) for k, v in labels.items()}}, indent=2))
