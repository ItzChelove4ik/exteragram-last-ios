"""Materialize the pinned Telegram source and apply the complete port."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from branding_assets import install_branding_assets

ROOT = Path(__file__).resolve().parents[1]


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def apply_patches(destination):
    # Order is explicit because several patches extend the same BUILD/source file.
    order = ["branding", "interface", "message_features", "message_more",
             "composer", "profile_phone", "send_as", "reactions", "translation",
             "speech", "export", "sideload", "authorization", "unsigned_rules", "wasi_host",
             "ghost_mode", "ghost_read", "deleted_log", "mod_commands", "translate_menu", "auto_translate", "observatory_observer", "round_video", "chat_list_background", "privacy_lens", "privacy_lens_chat", "privacy_push", "privacy_capture", "profile_banner"]
    prepared = {}
    total = 0
    for name in order:
        for patch in json.loads((ROOT / "port/patches" / f"{name}.json").read_text(encoding="utf-8")):
            path = destination / patch["path"]
            if path not in prepared:
                # Read the committed blob, preserving Unicode even if a local
                # checkout filter or editor has changed the working copy.
                repository = Path(subprocess.check_output(
                    ["git", "rev-parse", "--show-toplevel"], cwd=path.parent,
                    text=True).strip())
                prepared[path] = subprocess.check_output(
                    ["git", "show", "HEAD:" + path.relative_to(repository).as_posix()],
                    cwd=repository
                ).decode("utf-8").replace("\r\n", "\n")
            content = prepared[path]
            count = content.count(patch["old"])
            if count != patch["occurrences"]:
                raise RuntimeError(f"{name}: {patch['path']}: expected "
                                   f"{patch['occurrences']} matches, found {count}")
            prepared[path] = content.replace(patch["old"], patch["new"])
            total += 1
    # Validate every patch before writing any of them.
    for path, content in prepared.items():
        path.write_text(content, encoding="utf-8", newline="\n")
    print(f"Applied {total} checked patches to {len(prepared)} files", flush=True)


def install_modules(destination):
    for package in sorted((ROOT / "ios").iterdir()):
        if not (package / "Package.swift").exists():
            continue
        target = destination / "submodules" / package.name
        shutil.copytree(package / "Sources", target / "Sources", dirs_exist_ok=True)
        build = ('load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")\n')
        deps = ""
        if package.name == "ExteraResources":
            build += ('load("@build_bazel_rules_apple//apple:resources.bzl", '
                      '"apple_resource_bundle")\n'
                      'apple_resource_bundle(\n'
                      '    name = "ExteraResourcesBundle",\n'
                      '    bundle_name = "ExteraResources",\n'
                      '    resources = glob(["Sources/ExteraResources/Resources/**"]),\n'
                      ')\n')
            deps = '    data = [":ExteraResourcesBundle"],\n'
            accessor = '''import Foundation
private final class ExteraResourceBundleToken {}
extension Bundle {
    static let module: Bundle = {
        let containers = [Bundle(for: ExteraResourceBundleToken.self), Bundle.main]
        for container in containers {
            if let url = container.url(forResource: "ExteraResources", withExtension: "bundle"),
               let bundle = Bundle(url: url) { return bundle }
        }
        preconditionFailure("ExteraResources.bundle is missing")
    }()
}
'''
            (target / "Sources/ExteraResources/ResourceBundle.swift").write_text(accessor, encoding="utf-8")
        build += (f'swift_library(\n    name = "{package.name}",\n'
                  f'    module_name = "{package.name}",\n'
                  '    srcs = glob(["Sources/**/*.swift"]),\n' + deps +
                  '    visibility = ["//visibility:public"],\n)\n')
        (target / "BUILD").write_text(build, encoding="utf-8", newline="\n")
    for overlay in sorted((ROOT / "port/overlays").iterdir()):
        shutil.copytree(overlay, destination, dirs_exist_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, default=ROOT / ".build/upstream")
    parser.add_argument("--existing", action="store_true")
    parser.add_argument("--skip-submodules", action="store_true")
    args = parser.parse_args()
    destination = args.destination.resolve()
    manifest = json.loads((ROOT / "port/manifest.json").read_text(encoding="utf-8"))
    commit = manifest["upstream_commit"]
    if not args.existing:
        if destination.exists():
            raise RuntimeError(f"Destination exists: {destination}; use a clean directory")
        destination.mkdir(parents=True)
        run("git", "init", str(destination))
        run("git", "remote", "add", "origin",
            f"https://github.com/{manifest['upstream_repository']}.git", cwd=destination)
        run("git", "fetch", "--depth=1", "origin", commit, cwd=destination)
        run("git", "-c", "core.longpaths=true", "checkout", "--detach", "FETCH_HEAD", cwd=destination)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=destination, text=True).strip()
    if actual != commit:
        raise RuntimeError(f"Upstream commit mismatch: {actual}")
    if not args.skip_submodules:
        run("git", "submodule", "update", "--init", "--recursive", "--depth=1", "--jobs=4", cwd=destination)
    apply_patches(destination)
    install_modules(destination)
    install_branding_assets(destination)
    print(f"Prepared {destination} at {commit}", flush=True)


if __name__ == "__main__":
    main()
