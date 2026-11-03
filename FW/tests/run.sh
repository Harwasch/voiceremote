#!/usr/bin/env bash
# Purpose: reproducible host verification of pure firmware/client wire logic.
# Inputs: FW/app/{protocol,state,layout,audio} and synthetic contract fixtures.
# Verification: exits nonzero on any configure, compilation or test failure.
set -euo pipefail
cd "$(dirname "$0")/../.."
# Use locked codec bindings when prepared; native transport tests need no Opus headers.
python_args=()
if [[ -x FW/tools/ble_client/.venv/bin/python ]]; then
    python_args=(-DPython3_EXECUTABLE="$PWD/FW/tools/ble_client/.venv/bin/python")
fi
cmake -S FW/tests -B FW/build-host "${python_args[@]}"
cmake --build FW/build-host -j 4
ctest --test-dir FW/build-host --output-on-failure
