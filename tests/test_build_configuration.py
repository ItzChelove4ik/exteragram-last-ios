import importlib.util
from pathlib import Path
import json
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "extera_build_configuration", ROOT / "scripts/build_configuration.py"
)
configuration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configuration)


class BuildConfigurationTests(unittest.TestCase):
    def credentials(self, **overrides):
        # Synthetic values: these tests never contact Telegram or start a build.
        values = {"TELEGRAM_API_ID": "123456",
                  "TELEGRAM_API_HASH": "0123456789abcdef0123456789abcdef"}
        values.update(overrides)
        return values

    def test_both_credentials_are_required(self):
        for environment in ({}, {"TELEGRAM_API_ID": "123456"},
                            {"TELEGRAM_API_HASH": "0123456789abcdef0123456789abcdef"},
                            self.credentials(TELEGRAM_API_ID="   "),
                            self.credentials(TELEGRAM_API_HASH="")):
            with self.subTest(keys=tuple(environment)):
                with self.assertRaisesRegex(ValueError, "Set both"):
                    configuration.api_credentials(environment)

    def test_official_ios_credentials_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "official Telegram iOS"):
            configuration.api_credentials(self.credentials(TELEGRAM_API_ID="0008"))

    def test_api_id_must_fit_the_network_protocol(self):
        for value in ("0", "-1", "2147483648", "1.5", "abc", "1\n2"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "positive 32-bit"):
                    configuration.api_credentials(self.credentials(TELEGRAM_API_ID=value))

    def test_api_hash_must_be_complete_hex(self):
        for value in ("f" * 31, "f" * 33, "z" * 32, "a" * 16 + " " + "a" * 15):
            with self.subTest(length=len(value)):
                with self.assertRaisesRegex(ValueError, "32 hexadecimal"):
                    configuration.api_credentials(self.credentials(TELEGRAM_API_HASH=value))

    def test_whitespace_and_case_are_normalized(self):
        self.assertEqual(
            configuration.api_credentials(self.credentials(
                TELEGRAM_API_ID=" 00123456\n",
                TELEGRAM_API_HASH=" 0123456789ABCDEF0123456789ABCDEF\n")),
            ("123456", "0123456789abcdef0123456789abcdef")
        )

    def test_validation_errors_do_not_disclose_hash(self):
        environment = self.credentials(TELEGRAM_API_ID="8")
        try:
            configuration.api_credentials(environment)
        except ValueError as error:
            self.assertNotIn(environment["TELEGRAM_API_HASH"], str(error))
        else:
            self.fail("Official API ID should have been rejected")

    def test_missing_credentials_fail_before_reading_upstream(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "Set both"):
                configuration.load_build_configuration(Path(directory), {})
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_fork_configuration_replaces_official_credentials_as_a_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            upstream = source / "build-system/appstore-configuration.json"
            upstream.parent.mkdir()
            original = {"api_id": "8", "api_hash": "upstream-placeholder",
                        "bundle_id": "ph.telegra.Telegraph", "appstore_id": "686449807",
                        "enable_icloud": True, "is_appstore_build": "true"}
            upstream.write_text(json.dumps(original), encoding="utf-8")
            result = configuration.load_build_configuration(source, self.credentials())
            self.assertEqual(result["api_id"], "123456")
            self.assertEqual(result["api_hash"], self.credentials()["TELEGRAM_API_HASH"])
            self.assertEqual(result["bundle_id"], "com.itzchelove4ik.exteragram.lite")
            self.assertEqual(result["appstore_id"], original["appstore_id"])
            self.assertEqual(result["is_appstore_build"], "false")
            self.assertFalse(result["enable_icloud"])
            self.assertEqual(json.loads(upstream.read_text(encoding="utf-8")), original)


if __name__ == "__main__":
    unittest.main()
