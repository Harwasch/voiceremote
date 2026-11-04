#!/usr/bin/env bash
# Purpose: actual Worker + actual Rust CLI + actual Swift client, WS and LAN.
# Inputs: this checkout, cargo/swift/node/python3. Verified by a successful run.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export HEAVY_CPUS=4
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/voiceremote-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/voiceremote-swift-cache}"
if [[ ! -d SW/relay/node_modules/miniflare ]]; then
    npm --prefix SW/relay ci --ignore-scripts --no-audit --no-fund
fi
heavy cargo build --locked -j4 --manifest-path SW/desktop/Cargo.toml -p voiceremote-app --features e2e-test
heavy swift build -j 4 --package-path SW/ios/Packages/Pairing --product phone-e2e
heavy swift build -j 4 --package-path SYS/tests/e2e --product proxy-e2e
exec heavy python3 SYS/tests/e2e/run.py
