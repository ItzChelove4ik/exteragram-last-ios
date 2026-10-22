"""Install GlowGram's supplied artwork into the pinned iOS resource targets."""
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8", newline="\n")


def install_branding_assets(destination):
    from PIL import Image, ImageDraw

    with Image.open(ROOT / "assets/icon.png") as source:
        if source.size != (1024, 1024):
            raise ValueError("assets/icon.png must be a square 1024x1024 app icon")
        rgba = source.convert("RGBA")
        if rgba.getchannel("A").getextrema() != (255, 255):
            raise ValueError("assets/icon.png must be opaque for the iOS app icon")
        icon = rgba.convert("RGB")
    with Image.open(ROOT / "assets/foreground.png") as source:
        foreground = source.convert("RGBA")

    app = destination / "Telegram/Telegram-iOS"
    resampling = Image.Resampling.LANCZOS

    # Rebrand the welcome title while retaining Telegram's service-related text,
    # including instructions about receiving a login code in another client.
    for path in app.glob("*.lproj/Localizable.strings"):
        content = path.read_text(encoding="utf-8")
        content = re.sub(r'^("Tour\.Title1"\s*=\s*)"[^"\n]*";',
                         r'\1"GlowGram";', content, flags=re.MULTILINE)
        path.write_text(content, encoding="utf-8", newline="\n")

    # Icon Composer is the active primary app-icon input in this upstream.
    # Keep the supplied opaque artwork intact, without re-lighting the logo.
    composer = json.loads((app / "Telegram.icon/icon.json").read_text(encoding="utf-8"))
    group = composer["groups"][0]
    group["layers"] = [{"image-name": "icon.png", "name": "GlowGram", "glass": False}]
    group["blur-material"] = 0
    group["shadow"]["opacity"] = 0
    group["specular"] = False
    composer["groups"] = [group]
    composer_directory = app / "GlowGram.icon"
    write_json(composer_directory / "icon.json", composer)
    (composer_directory / "Assets").mkdir(exist_ok=True)
    shutil.copyfile(ROOT / "assets/icon.png", composer_directory / "Assets/icon.png")

    # Replace the ordinary default icon's iPhone/iPad/marketing raster sizes too.
    for relative in ("AppIcons.xcassets/BlueIcon.appiconset",
                     "DefaultAppIcon.xcassets/AppIconLLC.appiconset"):
        directory = app / relative
        manifest = json.loads((directory / "Contents.json").read_text(encoding="utf-8"))
        for entry in manifest["images"]:
            size = round(float(entry["size"].split("x")[0]) * float(entry["scale"][:-1]))
            filename = entry.setdefault("filename", f"GlowGram-{size}.png")
            icon.resize((size, size), resampling).save(directory / filename)
        write_json(directory / "Contents.json", manifest)

    for path in (app / "BlueIcon.alticon").glob("*.png"):
        with Image.open(path) as original:
            size = original.size
        icon.resize(size, resampling).save(path)

    def imageset(directory, base_size, render, template=False):
        directory.mkdir(parents=True, exist_ok=True)
        entries = []
        for scale in (1, 2, 3):
            filename = f"GlowGram@{scale}x.png"
            render(base_size * scale).save(directory / filename)
            entries.append({"idiom": "universal", "filename": filename, "scale": f"{scale}x"})
        manifest = {"images": entries, "info": {"author": "xcode", "version": 1}}
        if template:
            manifest["properties"] = {"template-rendering-intent": "template"}
        write_json(directory / "Contents.json", manifest)

    imageset(app / "Icons.xcassets/GlowGram.imageset", 60,
             lambda size: icon.resize((size, size), resampling))

    def shortcut_logo(size):
        mask = foreground.getchannel("A").resize((size, size), resampling)
        result = Image.new("RGBA", (size, size), "white")
        result.putalpha(mask)
        return result

    imageset(app / "Icons.xcassets/Shortcuts/AppIcon.imageset", 24, shortcut_logo, template=True)

    def settings_icon(size):
        result = icon.resize((size, size), resampling).convert("RGBA")
        mask = Image.new("L", (size, size))
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=size * 0.22, fill=255)
        result.putalpha(mask)
        return result

    imageset(destination / "submodules/TelegramUI/Images.xcassets/Settings/GlowGram.imageset",
             29, settings_icon)
    print("Installed GlowGram primary icon, raster variants, previews and shortcut logo", flush=True)
