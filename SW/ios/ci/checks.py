"""CI entry points: release version guard and runtime simulator selection."""
import json
from pathlib import Path
import re
import sys


def check_version(tag, spec):
    if not tag.startswith("ios-v"):
        return
    match = re.search(r'^    MARKETING_VERSION: "([^"]+)"$', spec, re.MULTILINE)
    if match is None or tag.removeprefix("ios-v") != match[1]:
        raise ValueError("Release tag must equal ios-v plus MARKETING_VERSION in project.yml")


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
        elif sys.argv[1] == "simulator":
            print(select_simulator(json.load(sys.stdin)))
        else:
            raise ValueError("Expected version or simulator command")
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
