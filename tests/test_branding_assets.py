import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("branding_assets", ROOT / "scripts/branding_assets.py")
branding = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(branding)


class BrandingAssetsTests(unittest.TestCase):
    def test_replacing_pdf_artwork_leaves_no_unassigned_images(self):
        with tempfile.TemporaryDirectory() as directory:
            imageset = Path(directory) / "AppIcon.imageset"
            imageset.mkdir()
            (imageset / "tlogo_24.pdf").write_bytes(b"%PDF-1.4\nold artwork\n")
            Image.new("RGB", (24, 24)).save(imageset / "OldIcon.png")
            (imageset / "notes.txt").write_text("Retain unrelated files", encoding="utf-8")
            (imageset / "Contents.json").write_text(json.dumps({
                "images": [{"filename": "tlogo_24.pdf", "idiom": "universal"}]
            }), encoding="utf-8")

            render = lambda size: Image.new("RGBA", (size, size), (255, 255, 255, 128))
            for _ in range(2):
                branding.install_imageset(imageset, 24, render, template=True)
                self.assertFalse((imageset / "tlogo_24.pdf").exists())
                self.assertFalse((imageset / "OldIcon.png").exists())
                manifest = json.loads((imageset / "Contents.json").read_text(encoding="utf-8"))
                assigned = {entry["filename"] for entry in manifest["images"]}
                actual = {path.name for path in imageset.iterdir() if path.suffix in branding.IMAGE_SUFFIXES}
                self.assertEqual(actual, assigned)
                self.assertEqual(len(assigned), 3)
                for entry in manifest["images"]:
                    with Image.open(imageset / entry["filename"]) as image:
                        size = 24 * int(entry["scale"][:-1])
                        self.assertEqual(image.size, (size, size))
                        self.assertEqual(image.getchannel("A").getextrema(), (128, 128))
                self.assertEqual(manifest["properties"]["template-rendering-intent"], "template")
                self.assertEqual((imageset / "notes.txt").read_text(encoding="utf-8"), "Retain unrelated files")


if __name__ == "__main__":
    unittest.main()
