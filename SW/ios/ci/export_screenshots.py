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


def export_manifest(raw: Path, output: Path, *, require_audits=True):
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
    if not screenshots or (require_audits and not audits):
        raise ValueError("Missing gallery or accessibility attachments; inspect the UI test result bundle")
    return index


def merge_checkpoints(raw: Path, checkpoints: Path):
    """Merge atomic runner-side artifacts, including an interrupted final test.

    Deduplicate identical label/content pairs already recovered from xcresult.
    Resolve and validate every source path before copying it into the export.
    """
    manifest_file = raw / "manifest.json"
    manifest = json.loads(manifest_file.read_text()) if manifest_file.exists() else []
    if not isinstance(manifest, list):
        manifest = [manifest]
    seen, usable, missing = set(), [], 0
    for test, item in attachments(manifest):
        source = (raw / item["exportedFileName"]).resolve()
        if not source.is_relative_to(raw.resolve()):
            raise ValueError("Attachment path escapes export directory")
        if source.is_file():
            seen.add((item.get("suggestedHumanReadableName"), hashlib.sha256(source.read_bytes()).digest()))
            usable.append({"testName": test, "attachments": [item]})
        else:
            missing += 1
    manifest = usable
    for metadata in sorted(checkpoints.glob("*.meta.json")):
        value = json.loads(metadata.read_text())
        for test, item in attachments(value):
            source = (checkpoints / item["exportedFileName"]).resolve()
            if not source.is_relative_to(checkpoints.resolve()):
                raise ValueError("Checkpoint path escapes runner directory")
            data = source.read_bytes()
            key = (item.get("suggestedHumanReadableName"), hashlib.sha256(data).digest())
            if key in seen:
                continue
            seen.add(key)
            filename = "checkpoint-" + source.name
            shutil.copyfile(source, raw / filename)
            manifest.append({"testName": test, "attachments": [dict(item, exportedFileName=filename)]})
    manifest_file.write_text(json.dumps(manifest))
    return missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xcresult", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--checkpoint-dir", type=Path,
        help="UITest runner Documents/ios-ui-checkpoints; survives an unfinalized xcresult")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    problems = []
    with tempfile.TemporaryDirectory(prefix="ios-ui-export-") as directory:
        raw = Path(directory)
        if args.xcresult.is_dir():
            try:
                subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.xcresult),
                                "--output-path", str(raw)], check=True, timeout=45)
            except (subprocess.SubprocessError, OSError) as error:
                problems.append("xcresult export unavailable: " + str(error))
        else:
            problems.append("xcresult bundle missing")
        # Keep an export directory/index even when tests never started. Always
        # upload steps can then preserve the reason as well as any actual PNGs.
        manifest = raw / "manifest.json"
        try:
            json.loads(manifest.read_text())
        except (OSError, ValueError):
            problems.append("xcresult attachment manifest missing or unreadable")
            manifest.write_text("[]")
        if args.checkpoint_dir and args.checkpoint_dir.is_dir():
            missing = merge_checkpoints(raw, args.checkpoint_dir)
            if missing:
                problems.append(f"Skipped {missing} unwritten xcresult attachments")
        (args.output / "export-status.json").write_text(json.dumps({
            "problems": problems, "checkpoint_directory_found": bool(args.checkpoint_dir and args.checkpoint_dir.is_dir()),
            "acceptance": "Partial artifacts do not establish a successful test run"}, indent=2) + "\n")
        export_manifest(raw, args.output, require_audits=not problems)
        if problems:
            print("Partial gallery recovered; inspect export-status.json and the test step outcome.")


if __name__ == "__main__":
    main()
