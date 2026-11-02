PYTHON ?= python3
HEAVY ?= heavy
export HEAVY_CPUS := 4
export HEAVY_MEM := 14G
export CARGO_BUILD_JOBS := 4
export PATH := $(HOME)/.cargo/bin:$(PATH)

.PHONY: generate check check-generated invariants rust swift typescript
generate:
	$(PYTHON) codegen/generate.py

# Regenerate without modifying files; a stale file is an error, never auto-fixed.
# Recursive makes keep heavy jobs sequential even when the caller uses make -j.
check:
	$(MAKE) check-generated
	$(MAKE) invariants
	$(MAKE) rust
	$(MAKE) swift
	$(MAKE) typescript

check-generated:
	$(PYTHON) codegen/generate.py --check

invariants:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s codegen -p 'test_*.py' -v

rust:
	@if [ -e ../SW/desktop/Cargo.lock ]; then lock_existed=yes; else lock_existed=no; fi; \
	trap 'if [ "$$lock_existed" = no ]; then $(PYTHON) -c '\''from pathlib import Path; Path("../SW/desktop/Cargo.lock").unlink(missing_ok=True)'\''; fi' EXIT; \
	$(HEAVY) cargo test -j4 -p voiceremote-protocol --manifest-path ../SW/desktop/Cargo.toml

swift:
	$(HEAVY) swift test -j 4 --package-path ../SW/ios/Packages/Protocol --cache-path /tmp/voiceremote-protocol-swift-cache --manifest-cache local

typescript:
	cd ../SW/relay && npm install --ignore-scripts --no-package-lock --no-audit --no-fund
	cd ../SW/relay && $(HEAVY) npm test
