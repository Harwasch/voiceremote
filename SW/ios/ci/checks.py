"""CI entry points: release version guard and runtime simulator selection."""
import json
from pathlib import Path
import re
import sys
import subprocess
import tomllib


def check_version(tag, spec):
    if not tag.startswith("ios-v"):
        return
    match = re.search(r'^    MARKETING_VERSION: "([^"]+)"$', spec, re.MULTILINE)
    if match is None or tag.removeprefix("ios-v") != match[1]:
        raise ValueError("Release tag must equal ios-v plus MARKETING_VERSION in project.yml")


def check_desktop_version(tag, version, bundle_version):
    if bundle_version != version:
        raise ValueError("Tauri bundle version differs from Cargo.toml")
    if tag.startswith("desktop-v") and tag != "desktop-v" + version:
        raise ValueError("Release tag differs from Cargo.toml")


def require_accepted_main(tag, commit, repository="."):
    if not tag.startswith(("ios-v", "desktop-v", "relay-v")):
        return
    result = subprocess.run(["git", "-C", str(repository), "merge-base", "--is-ancestor",
                             commit, "refs/remotes/origin/main"], capture_output=True)
    if result.returncode != 0:
        raise ValueError("Release commit must be accepted on origin/main")


def select_simulator(data):
    candidates = []
    for runtime, devices in data["devices"].items():
        match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?", runtime)
        if not match or int(match[1]) < 26:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        for device in devices:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                candidates.append((version, device["name"], device["udid"]))
    if not candidates:
        raise ValueError("No available iPhone simulator with iOS >= 26; inspect runner image inventory")
    return max(candidates)[2]


if __name__ == "__main__":
    try:
        if sys.argv[1] == "version":
            check_version(sys.argv[2], (Path(__file__).resolve().parents[1] / "project.yml").read_text())
            print("Version guard passed")
        elif sys.argv[1] == "desktop-version":
            root = Path(__file__).resolve().parents[2] / "desktop"
            version = tomllib.loads((root / "Cargo.toml").read_text())["workspace"]["package"]["version"]
            bundle = json.loads((root / "crates/tray/tauri.conf.json").read_text())["version"]
            check_desktop_version(sys.argv[2], version, bundle)
            print("Desktop version guard passed")
        elif sys.argv[1] == "accepted-main":
            require_accepted_main(sys.argv[2], sys.argv[3])
            print("Release ancestry guard passed")
        elif sys.argv[1] == "simulator":
            print(select_simulator(json.load(sys.stdin)))
        else:
            raise ValueError("Expected version, desktop-version, accepted-main or simulator command")
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
