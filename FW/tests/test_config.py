"""Release guards run before IDF import; no toolchain or network required."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ReleaseConfigTests(unittest.TestCase):
    def test_hook_forbidden_for_each_release_signal(self):
        root = Path(__file__).resolve().parents[2]
        scratch = root / 'AI/scratch'
        scratch.mkdir(exist_ok=True)
        for flags, signal in [(['-DREMOTE_RELEASE=ON'], {}),
                              ([], {'GITHUB_REF': 'refs/tags/fw-v0.3.0'}),
                              ([], {'CI_COMMIT_TAG': 'fw-v0.3.0'})]:
            with self.subTest(signal=flags or signal), tempfile.TemporaryDirectory(dir=scratch) as directory:
                env = os.environ.copy()
                env.pop('GITHUB_REF', None)
                env.pop('CI_COMMIT_TAG', None)
                env.update(signal)
                result = subprocess.run(['cmake', '-S', str(root/'FW'), '-B', directory,
                                         '-DREMOTE_TEST_HOOK=ON', *flags],
                                        env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('REMOTE_TEST_HOOK is forbidden in release builds', result.stderr)


if __name__ == '__main__':
    unittest.main()
