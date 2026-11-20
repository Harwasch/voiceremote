#!/usr/bin/env python3
"""Reproduce the synthetic demo adapter probe on Linux after AppModel swift test.

Inputs: built AppModel objects, App/UIDemo.swift, UITests/DemoAdapterProbe.swift.
Verification: local Linux; Apple SDK/UI behavior remains unverified.
"""
from pathlib import Path
import os
import subprocess
import tempfile


def main():
    ios = Path(__file__).resolve().parents[1]
    build = ios / "Packages/AppModel/.build/x86_64-unknown-linux-gnu/debug"
    link_file = build / "AppModelPackageTests.product/Objects.LinkFileList"
    objects = [line for line in link_file.read_text().splitlines() if "Tests.build/" not in line]
    with tempfile.TemporaryDirectory(prefix="ios-demo-probe-") as directory:
        binary = str(Path(directory) / "probe")
        subprocess.run(["swiftc", "-swift-version", "6", "-D", "DEBUG", "-module-cache-path",
            os.environ.get("CLANG_MODULE_CACHE_PATH", str(Path(directory) / "modules")),
            "-I", str(build / "Modules"), "-I", str(build / "CCryptoBoringSSL.build"), "-lstdc++",
            str(ios / "App/UIDemo.swift"), str(ios / "UITests/DemoAdapterProbe.swift"), *objects, "-o", binary], check=True)
        subprocess.run([binary], check=True)
        subprocess.run([binary, "--ui-running-task"], check=True)
        subprocess.run([binary, "--ui-biometric-refuse"], check=True)
        for flag in ["--ui-slow-prepare", "--ui-slow-finish", "--ui-capture-failure", "--ui-interrupt", ""]:
            subprocess.run([binary, "--ui-stop-probe", *([flag] if flag else [])], check=True)


if __name__ == "__main__":
    main()
