"""Pinned WASI SDK 33 for the actual macOS build-host architecture."""

_SDK_BUILD = """
exports_files(["bin/clang++"])
filegroup(
    name = "all_files",
    srcs = glob(["bin/**", "lib/**", "share/**"]),
    visibility = ["//visibility:public"],
)
"""

def _wasi_sdk_impl(repository_ctx):
    architecture = repository_ctx.os.arch
    if architecture in ["aarch64", "arm64"]:
        architecture = "arm64"
        checksum = "85c997a2665ead91673b5bb88b7d0df3fc8900df3bfa244f720d478187bbdc78"
    elif architecture in ["x86_64", "amd64"]:
        architecture = "x86_64"
        checksum = "18f3f201ba9734e6a4455b0b6410690395a55e9ffa9f6f5066f66083a94b93b3"
    else:
        fail("Unsupported WASI SDK macOS host: " + architecture)
    archive_root = "wasi-sdk-33.0-" + architecture + "-macos"
    repository_ctx.download_and_extract(
        url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/" + archive_root + ".tar.gz",
        sha256 = checksum,
        strip_prefix = archive_root,
    )
    repository_ctx.file("BUILD.bazel", _SDK_BUILD)

extera_wasi_sdk = repository_rule(implementation = _wasi_sdk_impl, configure = True)
