import unittest
from pathlib import Path
import subprocess
import tempfile
from checks import check_version, select_simulator, check_desktop_version, require_accepted_main


class ChecksTests(unittest.TestCase):
    def test_release_must_match_exactly(self):
        spec = '    MARKETING_VERSION: "0.1.0"\n'
        check_version("ios-v0.1.0", spec)
        check_version("ios-ci-smoke", spec)
        for tag in ["ios-v0.2.0", "ios-v0.1.0-beta", "ios-v"]:
            with self.assertRaises(ValueError):
                check_version(tag, spec)
        with self.assertRaises(ValueError):
            check_version("ios-v0.1.0", "")

    def test_desktop_versions_fail_closed(self):
        check_desktop_version("desktop-ci-smoke", "0.1.0", "0.1.0")
        check_desktop_version("desktop-v0.1.0", "0.1.0", "0.1.0")
        for tag in ["desktop-v", "desktop-v0.2.0", "desktop-v0.1.0-extra"]:
            with self.assertRaises(ValueError):
                check_desktop_version(tag, "0.1.0", "0.1.0")
        with self.assertRaises(ValueError):
            check_desktop_version("desktop-ci-smoke", "0.1.0", "0.2.0")

    def test_release_requires_accepted_main_history(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True).strip()
            git("init", "-b", "main")
            git("config", "user.email", "synthetic@example.invalid")
            git("config", "user.name", "Synthetic guard test")
            git("commit", "--allow-empty", "-m", "accepted")
            accepted = git("rev-parse", "HEAD")
            git("update-ref", "refs/remotes/origin/main", accepted)
            git("checkout", "-b", "candidate")
            git("commit", "--allow-empty", "-m", "unaccepted")
            candidate = git("rev-parse", "HEAD")
            for component in ["ios", "desktop", "relay"]:
                tag = component + "-v0.1.0"
                require_accepted_main(tag, accepted, directory)
                with self.assertRaises(ValueError):
                    require_accepted_main(tag, candidate, directory)
                require_accepted_main(component + "-ci-smoke", candidate, directory)
                with self.assertRaises(ValueError):
                    require_accepted_main(tag, "missing-commit", directory)
            git("update-ref", "-d", "refs/remotes/origin/main")
            with self.assertRaises(ValueError):
                require_accepted_main("ios-v0.1.0", accepted, directory)

    def test_desktop_workflow_guard_is_executable(self):
        # Exercise the actual inline workflow version guard, including its CLI call.
        root = Path(__file__).resolve().parents[3]
        workflow = (root / ".github/workflows/desktop.yml").read_text()
        start = workflow.index("      - name: Guard release and bundle versions")
        block = workflow[start:].split("      - name:", 2)[1]
        script = block.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in script.splitlines())
        import os
        for tag, success in [("desktop-ci-smoke", True), ("desktop-v9.9.9", False)]:
            result = subprocess.run(["python3", "-c", script], cwd=root,
                                    env={**os.environ, "GITHUB_REF_NAME": tag},
                                    capture_output=True)
            self.assertEqual(result.returncode == 0, success)

    def test_only_compatible_available_iphones_and_newest_runtime(self):
        def device(name, udid, available=True):
            return dict(name=name, udid=udid, isAvailable=available)
        data = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [device("iPhone 16", "old")],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [device("iPhone 16", "supported")],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-6": [
                device("iPhone 17", "unavailable", False), device("iPad Pro", "tablet"),
                device("iPhone 16", "newest")],
            "com.apple.CoreSimulator.SimRuntime.tvOS-26-6": [device("iPhone fake", "tv")],
        }}
        self.assertEqual(select_simulator(data), "newest")
        with self.assertRaises(ValueError):
            select_simulator({"devices": {}})


if __name__ == "__main__":
    unittest.main()
