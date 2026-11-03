#!/usr/bin/env bash
# Purpose: reproducible host verification of pure firmware/client wire logic.
# Inputs: FW/app/{protocol,state,layout} and synthetic contract fixtures.
# Verification: exits nonzero on any configure, compilation or test failure.
set -euo pipefail
cd "$(dirname "$0")/../.."
cmake -S FW/tests -B FW/build-host
cmake --build FW/build-host -j 4
ctest --test-dir FW/build-host --output-on-failure
