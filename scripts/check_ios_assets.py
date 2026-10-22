"""Compile the application's asset catalogs with Xcode before the full IPA build."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / ".build/upstream")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.exit(1, "Xcode asset validation requires macOS.\n")
    source = args.source.resolve()
    # Match the inputs reported by the pinned application's AssetCatalogCompile
    # action, including catalogs pulled in through framework resource dependencies.
    catalogs = [
        "Telegram/Telegram-iOS/Icons.xcassets",
        "submodules/LegacyComponents/LegacyImages.xcassets",
        "submodules/PasswordSetupUI/PasswordSetupUIImages.xcassets",
        "submodules/TelegramUI/Images.xcassets",
        "submodules/TelegramUI/Components/Calls/CallScreen/CallScreenAssets.xcassets",
        "Telegram/Telegram-iOS/GlowGram.icon",
    ]
    for relative in catalogs:
        if not (source / relative).is_dir():
            parser.exit(1, f"Missing asset catalog: {relative}\n")
    with tempfile.TemporaryDirectory(prefix="asset-check-", dir=source.parent) as directory:
        output = Path(directory)
        compiled = output / "compiled"
        compiled.mkdir()
        subprocess.run([
            "xcrun", "actool", "--compile", str(compiled),
            "--errors", "--warnings", "--notices", "--output-format", "human-readable-text",
            "--platform", "iphoneos", "--minimum-deployment-target", "15.0",
            "--compress-pngs", "--app-icon", "GlowGram",
            "--target-device", "iphone", "--target-device", "ipad",
            "--output-partial-info-plist", str(output / "Info.plist"),
            *[str(source / relative) for relative in catalogs],
        ], check=True)
    print("Xcode asset catalog validation passed.", flush=True)


if __name__ == "__main__":
    main()
