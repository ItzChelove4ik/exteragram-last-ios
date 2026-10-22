"""Build the real Telegram application for arm64 without Apple signing material."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import zipfile

from build_configuration import load_build_configuration

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT / ".build/upstream")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--build-number", type=int, default=1)
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    try:
        configuration = load_build_configuration(source, os.environ)
    except ValueError as error:
        parser.exit(1, f"API configuration error: {error}\n")
    os.chdir(source)
    sys.path.insert(0, str(source / "build-system/Make"))
    from BazelLocation import locate_bazel
    from BuildConfiguration import build_configuration_from_json
    from Make import BazelCommandLine

    bazel = locate_bazel(str(source), None, None)
    config_path = source / "build-input/glowgram-configuration.json"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(configuration), encoding="utf-8")
    repository = source / "build-input/configuration-repository"
    repository.mkdir(parents=True, exist_ok=True)
    (repository / "MODULE.bazel").write_text('module(name = "build_configuration")\n')
    (repository / "WORKSPACE").touch()
    (repository / "BUILD").touch()
    (repository / "provisioning").mkdir(exist_ok=True)
    (repository / "provisioning/BUILD").write_text('exports_files([])\n')
    build_configuration_from_json(str(config_path)).write_to_variables_file(
        bazel_path=bazel, use_xcode_managed_codesigning=False,
        aps_environment="", path=str(repository / "variables.bzl"))
    command = BazelCommandLine(bazel=bazel, override_bazel_version=False,
                              override_xcode_version=True, bazel_user_root=None)
    command.set_configuration("release_arm64")
    command.set_build_number(args.build_number)
    command.set_disable_provisioning_profiles()
    command.common_args += ["--features=disable_legacy_signing",
                            "--//Telegram:disableExtensions", "--jobs=3"]
    command.invoke_build()
    ipa = source / "bazel-bin/Telegram/Telegram.ipa"
    with zipfile.ZipFile(ipa) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise RuntimeError(f"Corrupt IPA member: {corrupt}")
        names = archive.namelist()
        if not any(n.startswith("Payload/") and n.endswith(".app/Info.plist") for n in names):
            raise RuntimeError("The output does not contain an iOS application")
        if any(n.endswith("embedded.mobileprovision") for n in names):
            raise RuntimeError("Unexpected provisioning profile in unsigned IPA")
    output.mkdir(parents=True, exist_ok=True)
    destination = output / "GlowGram-unsigned.ipa"
    shutil.copyfile(ipa, destination)
    print(f"IPA: {destination} ({destination.stat().st_size} bytes)", flush=True)


if __name__ == "__main__":
    main()
