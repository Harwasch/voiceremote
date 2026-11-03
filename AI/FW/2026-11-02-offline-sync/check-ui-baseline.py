#!/usr/bin/env python3
"""Purpose: verify unchanged baseline Orb PNGs. Inputs: saved SHA256 + preview PNGs.
Verified: the twelve baseline outputs match after offline UI additions.
Run after FW/tools/ui_preview/run.sh from any directory; exits nonzero on drift.
"""
import hashlib
import json
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parents[2]
expected = json.loads((here / "ui-baseline-sha256.json").read_text())
changed = [name for name, digest in expected.items()
           if hashlib.sha256((root / "FW/build-preview" / (name + ".png")).read_bytes()).hexdigest() != digest]
print(f"Baseline PNGs: {len(expected)} checked; changed: {changed}")
raise SystemExit(bool(changed))
