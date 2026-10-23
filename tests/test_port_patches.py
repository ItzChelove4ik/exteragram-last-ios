import importlib.util
from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load_prepare_upstream():
    # Import without executing main(); the module only defines functions.
    import sys
    scripts = str(ROOT / "scripts")
    sys.path.insert(0, scripts)
    try:
        spec = importlib.util.spec_from_file_location(
            "extera_prepare_upstream", ROOT / "scripts/prepare_upstream.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.remove(scripts)


class PortPatchCatalogTests(unittest.TestCase):
    """Structural validation of the port's patch catalog.

    These tests do not need the pinned Telegram source or macOS: they check
    that every referenced patch file exists, parses, and that every patch
    that is applied to a repo-controlled source file also compiles into a
    deterministic order. Anchor matching against the real upstream is
    exercised on the build machine by scripts/prepare_upstream.py itself,
    which refuses to write anything when an anchor does not match.
    """

    @classmethod
    def setUpClass(cls):
        cls.module = load_prepare_upstream()
        source = (ROOT / "scripts/prepare_upstream.py").read_text(encoding="utf-8")
        start = source.index("order = [")
        end = source.index("]", start)
        cls.order = [
            name.strip().strip('"')
            for name in source[start + len("order = ["):end].split(",")
            if name.strip()
        ]

    def test_every_patch_file_exists_and_parses(self):
        for name in self.order:
            path = ROOT / "port/patches" / f"{name}.json"
            self.assertTrue(path.exists(), f"missing patch file: {name}.json")
            patches = json.loads(path.read_text(encoding="utf-8"))
            self.assertIsInstance(patches, list, name)
            for patch in patches:
                for key in ("path", "old", "new", "occurrences"):
                    self.assertIn(key, patch, f"{name}: missing key {key}")
                self.assertGreaterEqual(patch["occurrences"], 1, name)
                self.assertTrue(patch["path"], f"{name}: empty path")
                self.assertTrue(patch["old"], f"{name}: empty anchor")
                self.assertTrue(patch["new"], f"{name}: empty replacement")

    def test_order_covers_every_patch_file(self):
        on_disk = {p.stem for p in (ROOT / "port/patches").glob("*.json")}
        self.assertEqual(set(self.order), on_disk,
                         "order list and patch files diverge")

    def test_replacements_are_valid_text(self):
        for name in self.order:
            patches = json.loads(
                (ROOT / "port/patches" / f"{name}.json").read_text(encoding="utf-8"))
            for patch in patches:
                self.assertIsInstance(patch["old"], str)
                self.assertIsInstance(patch["new"], str)
                self.assertNotEqual(patch["old"], patch["new"], name)

    def test_build_patches_only_add_dependencies(self):
        # The one sanctioned replacement changes the icon folder name.
        allowed_removed = {'composer_icon_folders = ["Telegram"]'}
        for name in self.order:
            patches = json.loads(
                (ROOT / "port/patches" / f"{name}.json").read_text(encoding="utf-8"))
            for patch in patches:
                if not patch["path"].endswith("BUILD"):
                    continue
                removed = set(patch["old"].splitlines()) - set(patch["new"].splitlines())
                removed -= allowed_removed
                self.assertFalse(
                    any('"' in line for line in removed),
                    f"{name}: BUILD patch removes lines: {removed}")

    def test_overlays_do_not_shadow_patches(self):
        # Files copied by overlays into submodules must not also be patched
        # (they are not in upstream HEAD and would fail anchor validation).
        overlays = ROOT / "port/overlays"
        overlay_paths = set()
        if overlays.exists():
            for path in overlays.rglob("*"):
                if path.is_file():
                    relative = path.relative_to(overlays).as_posix()
                    # strip the overlay root directory and submodule mapping
                    parts = relative.split("/")
                    if len(parts) > 2 and parts[1] == "submodules":
                        overlay_paths.add("submodules/" + "/".join(parts[2:]))
        for name in self.order:
            patches = json.loads(
                (ROOT / "port/patches" / f"{name}.json").read_text(encoding="utf-8"))
            for patch in patches:
                self.assertNotIn(
                    patch["path"], overlay_paths,
                    f"{name}: {patch['path']} is both an overlay file and a patch target")


if __name__ == "__main__":
    unittest.main()
