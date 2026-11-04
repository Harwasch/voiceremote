#!/usr/bin/env python3
"""Export named XCTest gallery attachments with Xcode's xcresulttool.

Inputs: an xcresult bundle containing gallery__/audit__ attachments.
Verification: fixture-based Linux tests; real Xcode export unverified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def attachments(value, test="unknown"):
    """Accept xcresulttool's per-test manifest, retaining the test identity."""
    if isinstance(value, list):
        for child in value:
            yield from attachments(child, test)
    elif isinstance(value, dict):
        test = value.get("testName", value.get("testIdentifier", test))
        if "exportedFileName" in value:
            yield test, value
        else:
            for child in value.values():
                if isinstance(child, (list, dict)):
                    yield from attachments(child, test)


def export_manifest(raw: Path, output: Path):
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((raw / "manifest.json").read_text())
    screenshots, audits, names = [], [], set()
    for test, attachment in attachments(manifest):
        label = attachment.get("suggestedHumanReadableName", "")
        if not label.startswith(("gallery__", "audit__")):
            continue
        source = (raw / attachment["exportedFileName"]).resolve()
        if not source.is_relative_to(raw.resolve()):
            raise ValueError("Attachment path escapes export directory")
        is_screen = label.startswith("gallery__")
        suffix = ".png" if is_screen else ".json"
        stem = re.sub(r"\.(png|json)$", "", label, flags=re.I)
        stem = re.sub(r"[^A-Za-z0-9_-]+", "-", stem).strip("-")[:180]
        name = stem + suffix
        if name in names:
            digest = hashlib.sha256((str(test) + source.name).encode()).hexdigest()[:12]
            name = stem + "__" + digest + suffix
        if name in names:
            raise ValueError("Duplicate attachment entry: " + name)
        names.add(name)
        if is_screen:
            if not source.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("Gallery screenshot is not a PNG: " + source.name)
            shutil.copyfile(source, output / name)
            screenshots.append({"label": re.sub(r"\.png$", "", label.removeprefix("gallery__"), flags=re.I), "file": name, "test": test})
        else:
            report = json.loads(source.read_text())
            if not isinstance(report.get("findings"), list):
                raise ValueError("Audit attachment has no findings list")
            shutil.copyfile(source, output / name)
            audits.append({"label": report["screen"], "file": name, "test": test, "findings": report["findings"]})
    index = {"verification": "Simulator review only; device acceptance unverified",
             "screenshots": sorted(screenshots, key=lambda v: (v["label"], v["file"])),
             "accessibility": {"mode": "report-only", "audits": audits,
                               "finding_count": sum(len(a["findings"]) for a in audits)}}
    (output / "index.json").write_text(json.dumps(index, indent=2) + "\n")
    count = index["accessibility"]["finding_count"]
    summary = f"UI gallery: {len(screenshots)} labelled PNGs; {len(audits)} accessibility audits; {count} findings (report-only).\n"
    (output / "README.txt").write_text(summary + "Open index.json for screen labels, test names and all findings.\n"
        "A partial gallery may come from a failed test: check the job and ios-ui-results artifact.\n"
        "Apple compilation, simulator behavior and accessibility acceptance remain unverified until a successful ios-ui-* run.\n")
    print(summary, end="")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(summary + "\nDownload **ios-screenshots**, then open `index.json`; findings are not waived or a passing accessibility baseline.\n")
    if not screenshots or not audits:
        raise ValueError("Missing gallery or accessibility attachments; inspect the UI test result bundle")
    return index


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xcresult", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if not args.xcresult.is_dir():
        parser.error("xcresult bundle missing: UI build/test did not produce results")
    with tempfile.TemporaryDirectory(prefix="ios-ui-export-") as directory:
        raw = Path(directory)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.xcresult),
                        "--output-path", str(raw)], check=True)
        export_manifest(raw, args.output)


if __name__ == "__main__":
    main()
