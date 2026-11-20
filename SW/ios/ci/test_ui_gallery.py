"""Synthetic exporter and release-isolation checks; no Apple frameworks required."""
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

from export_screenshots import export_manifest, main, merge_checkpoints
import subprocess

IOS = Path(__file__).resolve().parents[1]


def without_debug(source):
    """Grep-equivalent view with DEBUG disabled, including nested conditionals."""
    stack, lines = [], []
    for line in source.splitlines():
        directive = line.strip()
        if directive.startswith("#if "):
            stack.append(False if directive == "#if DEBUG" else None)
        elif directive == "#else":
            if stack[-1] is not None:
                stack[-1] = not stack[-1]
        elif directive == "#endif":
            stack.pop()
        elif False not in stack:
            lines.append(line)
    if stack:
        raise ValueError("Unbalanced Swift conditional compilation")
    return "\n".join(lines)


class GalleryTests(unittest.TestCase):
    def fixture(self, raw, entries=None):
        (raw / "screen.png").write_bytes(b"\x89PNG\r\n\x1a\nsynthetic")
        (raw / "audit.json").write_text(json.dumps({"screen": "light__default__home", "mode": "report-only",
            "findings": [{"type": "contrast", "summary": "Synthetic finding", "detail": "Synthetic detail"}]}))
        if entries is None:
            entries = [
                {"exportedFileName": "screen.png", "suggestedHumanReadableName": "gallery__light__default__home.png"},
                {"exportedFileName": "audit.json", "suggestedHumanReadableName": "audit__light__default__home.json"},
            ]
        (raw / "manifest.json").write_text(json.dumps([{"testName": "Synthetic/testGallery()", "attachments": entries}]))
        return entries

    def test_named_png_index_and_all_audit_findings(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = Path(directory); self.fixture(raw)
            output = raw / "out"
            with patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": str(raw / "summary")}, clear=False):
                index = export_manifest(raw, output)
            self.assertEqual(index["screenshots"][0]["label"], "light__default__home")
            self.assertEqual(index["screenshots"][0]["test"], "Synthetic/testGallery()")
            self.assertEqual(index["accessibility"]["finding_count"], 1)
            self.assertEqual(json.loads((output / "index.json").read_text()), index)
            self.assertTrue((output / "gallery__light__default__home.png").exists())
            self.assertIn("report-only", (raw / "summary").read_text())

    def test_duplicate_human_labels_do_not_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = Path(directory); entries = self.fixture(raw)
            (raw / "second.png").write_bytes((raw / "screen.png").read_bytes())
            entries.append(dict(entries[0], exportedFileName="second.png"))
            self.fixture(raw, entries)
            index = export_manifest(raw, raw / "out")
            self.assertEqual(len({v["file"] for v in index["screenshots"]}), 2)

    def test_export_rejects_missing_empty_invalid_or_escaping_data(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = Path(directory); entries = self.fixture(raw)
            for invalid in [[], [dict(entries[0], exportedFileName="../outside.png")],
                            [dict(entries[0], exportedFileName="audit.json")]]:
                self.fixture(raw, invalid)
                with self.assertRaises(ValueError):
                    export_manifest(raw, raw / "out")
            self.fixture(raw)
            (raw / "audit.json").write_text('{"screen":"synthetic"}')
            with self.assertRaises(ValueError):
                export_manifest(raw, raw / "out")

    def test_cli_requests_all_attachments_from_finalized_xcresult(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "UI.xcresult"; bundle.mkdir()
            (bundle / "Info.plist").write_bytes(b"synthetic finalized bundle marker")
            def sdk_export(command, **kwargs):
                self.assertEqual(command[:4], ["xcrun", "xcresulttool", "export", "attachments"])
                self.assertNotIn("--only-failures", command)
                self.assertNotIn("--legacy", command)
                self.assertEqual(Path(command[command.index("--path") + 1]), bundle.resolve())
                output = Path(command[command.index("--output-path") + 1])
                self.assertTrue(output.is_absolute())
                self.assertFalse(output.exists())
                self.assertTrue(kwargs["check"])
                self.assertTrue(kwargs["capture_output"])
                output.mkdir(); self.fixture(output)
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
            output = Path(directory) / "out"
            with patch("sys.argv", ["export_screenshots.py", str(bundle), str(output)]), \
                 patch("export_screenshots.subprocess.run", side_effect=sdk_export) as run:
                main()
            run.assert_called_once()
            self.assertFalse(json.loads((output / "export-status.json").read_text())["problems"])
            self.assertEqual(len(json.loads((output / "index.json").read_text())["screenshots"]), 1)

    def test_finalized_reader_usage_error_preserves_stderr_and_checkpoint_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); bundle = root / "UI.xcresult"; bundle.mkdir()
            (bundle / "Info.plist").write_bytes(b"synthetic marker")
            checkpoints = root / "runner"; checkpoints.mkdir()
            entries = self.fixture(checkpoints)
            (checkpoints / "shot.meta.json").write_text(json.dumps({"testName": "Synthetic/testFlow", "attachments": entries}))
            output = root / "out"
            failure = subprocess.CalledProcessError(64, "xcresulttool", stderr="SDK reader rejected this synthetic bundle")
            with patch("sys.argv", ["export_screenshots.py", str(bundle), str(output), "--checkpoint-dir", str(checkpoints)]), \
                 patch("export_screenshots.subprocess.run", side_effect=failure):
                main()
            self.assertIn("SDK reader rejected", " ".join(json.loads((output / "export-status.json").read_text())["problems"]))
            self.assertEqual(len(json.loads((output / "index.json").read_text())["screenshots"]), 1)

    def test_unfinished_and_timed_out_bundles_recover_checkpoint_pngs(self):
        for finalized in (False, True):
            with self.subTest(finalized=finalized), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); checkpoints = root / "runner"; checkpoints.mkdir()
                entries = self.fixture(checkpoints)
                (checkpoints / "shot.meta.json").write_text(json.dumps({"testName": "Interrupted/testFlow", "attachments": entries[:1]}))
                bundle = root / "UI.xcresult"; bundle.mkdir()
                if finalized:
                    (bundle / "Info.plist").write_bytes(b"synthetic finalized marker")
                output = root / "out"
                with patch("sys.argv", ["export_screenshots.py", str(bundle), str(output), "--checkpoint-dir", str(checkpoints)]), \
                     patch("export_screenshots.subprocess.run", side_effect=subprocess.TimeoutExpired("xcresulttool", 45)) as run:
                    main()
                if finalized:
                    run.assert_called_once()
                else:
                    run.assert_not_called()
                index = json.loads((output / "index.json").read_text())
                self.assertEqual(len(index["screenshots"]), 1)
                self.assertEqual(index["screenshots"][0]["test"], "Interrupted/testFlow")
                self.assertEqual(index["accessibility"]["audits"], [])
                self.assertTrue((output / index["screenshots"][0]["file"]).is_file())
                self.assertTrue(json.loads((output / "export-status.json").read_text())["problems"])

    def test_missing_bundle_recovers_audit_and_png_checkpoints(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); checkpoints = root / "runner"; checkpoints.mkdir()
            entries = self.fixture(checkpoints)
            (checkpoints / "shot.meta.json").write_text(json.dumps({"testName": "Synthetic/testFlow", "attachments": entries}))
            output = root / "out"
            with patch("sys.argv", ["export_screenshots.py", str(root / "missing"), str(output), "--checkpoint-dir", str(checkpoints)]):
                main()
            index = json.loads((output / "index.json").read_text())
            self.assertEqual(index["accessibility"]["finding_count"], 1)
            self.assertEqual(len(index["screenshots"]), 1)

    def test_checkpoint_merge_deduplicates_and_drops_unwritten_bundle_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); raw = root / "raw"; raw.mkdir(); checkpoints = root / "runner"; checkpoints.mkdir()
            entries = self.fixture(raw)
            self.fixture(raw, entries + [dict(entries[0], exportedFileName="unwritten.png")])
            self.fixture(checkpoints)
            (checkpoints / "duplicate.meta.json").write_text(json.dumps({"testName": "Runner/testFlow", "attachments": entries}))
            self.assertEqual(merge_checkpoints(raw, checkpoints), 1)
            index = export_manifest(raw, root / "out")
            self.assertEqual(len(index["screenshots"]), 1)
            self.assertEqual(len(index["accessibility"]["audits"]), 1)

    def test_first_gallery_covers_every_approved_default_screen_without_audit_delays(self):
        gallery = (IOS / "UITests/VoiceRemoteUITests.swift").read_text()
        first = gallery.split("func test00MainScreenGallery() throws {", 1)[1].split("func testLargestDynamicTypeMainScreens", 1)[0]
        for screen in ("Main", "Listening", "AIControl", "Destination", "Approval", "History", "Devices", "Pairing", "Agents"):
            self.assertIn(f'shot("{screen}", audit: false)', first)
        self.assertIn("--ui-running-task", first)
        self.assertIn("--ui-holding-preview", first)

    def test_demo_is_absent_without_debug(self):
        # Every launch-argument consumer, fake, construction hook and demo UI is
        # inside #if DEBUG. This is a source grep guard, not an Apple Release build.
        self.assertEqual(without_debug("#if DEBUG\nouter\n#if os(iOS)\ninner\n#endif\n#else\nrelease\n#endif"), "release")
        for path in (IOS / "App").rglob("*.swift"):
            with self.subTest(path=path.name):
                self.assertNotRegex(without_debug(path.read_text()), r"UIDemo|Demo(?:Capture|Speech|Brain|Target|Pairing|Biometric|Journal|Checkpoint|AgentTransport)|--ui-|\.demo\b|\bdemo[A-Z]\w*\b")
        runtime = (IOS / "App/AppRuntime.swift").read_text()
        self.assertIn("if UIDemo.requested", runtime)
        self.assertNotIn("ProcessInfo.processInfo.arguments", without_debug(runtime))

    def test_ui_build_and_simulator_preparation_precede_timed_tests(self):
        workflow = (IOS.parents[1] / ".github/workflows/ios.yml").read_text()
        job = workflow.split("  ui-gallery:\n", 1)[1].split("  testflight:", 1)[0]
        steps = job.split("      - name: ")
        build = next((step for step in steps if "xcodebuild build-for-testing " in step), "")
        self.assertTrue(build, "Compile UI tests separately from the test watchdog")
        self.assertNotIn("gtimeout", build)
        boot = next(step for step in steps if 'xcrun simctl bootstatus "$SIMULATOR_ID" -b' in step)
        commands = [f'xcrun simctl {action} "$SIMULATOR_ID"' for action in ("shutdown", "erase", "boot", "bootstatus")]
        for first, second in zip(commands, commands[1:]):
            self.assertLess(boot.index(first), boot.index(second))
        self.assertNotIn("|| true", boot, "Simulator preparation must fail visibly")
        tests = next(step for step in steps if "xcodebuild test-without-building " in step)
        self.assertIn("gtimeout --signal=INT --kill-after=20s 600s xcodebuild test-without-building", tests)
        for step in (build, tests):
            self.assertIn('-destination "platform=iOS Simulator,id=$SIMULATOR_ID"', step)
            self.assertIn("-derivedDataPath DerivedData", step)
            self.assertIn("SIMULATOR_ID: ${{ steps.device.outputs.id }}", step)
        self.assertLess(job.index(build), job.index(boot))
        self.assertLess(job.index(boot), job.index(tests))

    def test_ui_job_and_scheme_are_separate_and_unsigned(self):
        workflow = (IOS.parents[1] / ".github/workflows/ios.yml").read_text()
        job = workflow.split("  ui-gallery:\n", 1)[1].split("  testflight:", 1)[0]
        self.assertIn("startsWith(github.ref, 'refs/tags/ios-ui-') || github.event_name == 'workflow_dispatch'", job)
        for required in ["timeout-minutes: 30", "-configuration Debug", "CODE_SIGNING_ALLOWED=NO", "-jobs 4", "name: ios-screenshots", "if: always()", "gtimeout --signal=INT --kill-after=20s 600s",
                         "-test-timeouts-enabled YES", "-maximum-test-execution-time-allowance 90", "--checkpoint-dir"]:
            self.assertIn(required, job)
        spec = (IOS / "project.yml").read_text()
        self.assertIn("type: bundle.ui-testing", spec)
        self.assertRegex(spec, r"VoiceRemoteUI:\n[\s\S]*targets: \[VoiceRemoteUITests\]")
        self.assertIn("targets: [VoiceRemoteTests]", spec)
        gallery = (IOS / "UITests/VoiceRemoteUITests.swift").read_text()
        self.assertNotIn("--ui-dark", gallery, "Routine CI must not repeat the gallery in dark mode")
        self.assertIn("testLargestDynamicTypeMainScreens", gallery)


if __name__ == "__main__":
    unittest.main()
