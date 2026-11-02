import unittest
from checks import check_version, select_simulator


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
