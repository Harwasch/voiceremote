"""Synthetic exporter and release-isolation checks; no Apple frameworks required."""
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

from export_screenshots import export_manifest, main

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

    def test_cli_requests_all_attachments_from_xcresult(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "UI.xcresult"; bundle.mkdir()
            with patch("sys.argv", ["export_screenshots.py", str(bundle), str(Path(directory) / "out")]), \
                 patch("export_screenshots.subprocess.run") as run, \
                 patch("export_screenshots.export_manifest"):
                main()
            command = run.call_args.args[0]
            self.assertEqual(command[:4], ["xcrun", "xcresulttool", "export", "attachments"])
            self.assertNotIn("--only-failures", command)
            self.assertTrue(run.call_args.kwargs["check"])

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

    def test_ui_job_and_scheme_are_separate_and_unsigned(self):
        workflow = (IOS.parents[1] / ".github/workflows/ios.yml").read_text()
        job = workflow.split("  ui-gallery:\n", 1)[1].split("  testflight:", 1)[0]
        self.assertIn("startsWith(github.ref, 'refs/tags/ios-ui-') || github.event_name == 'workflow_dispatch'", job)
        for required in ["timeout-minutes: 30", "-configuration Debug", "CODE_SIGNING_ALLOWED=NO", "-jobs 4", "name: ios-screenshots", "if: always()"]:
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
