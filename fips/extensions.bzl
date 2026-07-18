"""Bzlmod extension that fetches exact, integrity-pinned FIPS build inputs."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

_SOURCE_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "srcs",
    srcs = glob(["**"], exclude = [".git/**"]),
)

exports_files(glob(["*"]))
"""

_OTP_SOURCE_BUILD = _SOURCE_BUILD

_SYSROOT_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "sysroot",
    srcs = glob(
        ["**"],
        exclude = ["lib/systemd/**"],
    ),
)

exports_files(["usr/include/stdio.h"])
"""

_DEFAULT_SOURCES = {
    "boringssl_src": struct(
        urls = [
            "https://web.archive.org/web/20250515081911id_/https://commondatastorage.googleapis.com/chromium-boringssl-fips/boringssl-a430310d6563c0734ddafca7731570dfb683dc19.tar.xz",
            "https://commondatastorage.googleapis.com/chromium-boringssl-fips/boringssl-a430310d6563c0734ddafca7731570dfb683dc19.tar.xz",
        ],
        sha256 = "2d5339b756dbf1ceb4fdc4b1c8f19e32ded055292dc57827a6592f15ca9d359f",
        strip_prefix = "boringssl",
    ),
    "elixir_src": struct(
        urls = ["https://github.com/elixir-lang/elixir/archive/refs/tags/v1.20.2.tar.gz"],
        sha256 = "1a25bbf9a9016651fc332eecc02bb9681d0b8e722c2e256e73ddb88fbce6e6b0",
        strip_prefix = "elixir-1.20.2",
    ),
    "openssl_core_src": struct(
        urls = ["https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz"],
        sha256 = "a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8",
        strip_prefix = "openssl-3.5.7",
    ),
    "openssl_fips_src": struct(
        urls = ["https://github.com/openssl/openssl/releases/download/openssl-3.1.2/openssl-3.1.2.tar.gz"],
        sha256 = "a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539",
        strip_prefix = "openssl-3.1.2",
    ),
    "otp_src": struct(
        urls = ["https://github.com/erlang/otp/archive/refs/tags/OTP-29.0.3.tar.gz"],
        sha256 = "edef13778a449490bc183134e442a955b134d69c56075d97765d8d4951d8d2bb",
        strip_prefix = "otp-OTP-29.0.3",
    ),
    "linux_amd64_sysroot": struct(
        urls = ["https://commondatastorage.googleapis.com/chrome-linux-sysroot/52d61d4446ffebfaa3dda2cd02da4ab4876ff237853f46d273e7f9b666652e1d"],
        sha256 = "52d61d4446ffebfaa3dda2cd02da4ab4876ff237853f46d273e7f9b666652e1d",
        strip_prefix = "",
    ),
    "linux_arm64_sysroot": struct(
        urls = ["https://commondatastorage.googleapis.com/chrome-linux-sysroot/c7176a4c7aacbf46bda58a029f39f79a68008d3dee6518f154dcf5161a5486d8"],
        sha256 = "c7176a4c7aacbf46bda58a029f39f79a68008d3dee6518f154dcf5161a5486d8",
        strip_prefix = "",
    ),
    "musl_src": struct(
        urls = ["https://git.musl-libc.org/cgit/musl/snapshot/musl-b306b16af15c89a04d8e0c55cac2dadbeb39c083.tar.gz"],
        sha256 = "79325f4b37bc827346c45556787b0441f7cacad70a2362484e7e169e072fb7a5",
        strip_prefix = "musl-b306b16af15c89a04d8e0c55cac2dadbeb39c083",
    ),
}

_source = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "sha256": attr.string(mandatory = True),
    "strip_prefix": attr.string(mandatory = True),
    "urls": attr.string_list(mandatory = True),
})

def _validate_override(tag):
    if tag.name not in _DEFAULT_SOURCES:
        fail("unknown rules_fips source override: %s" % tag.name)
    if len(tag.sha256) != 64:
        fail("source %s must use a 64-character SHA-256 digest" % tag.name)
    if not tag.urls:
        fail("source %s must provide at least one URL" % tag.name)
    for url in tag.urls:
        if not url.startswith("https://"):
            fail("source %s URL must use HTTPS: %s" % (tag.name, url))

def _fips_sources_impl(module_ctx):
    overrides = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.source:
            if not mod.is_root:
                fail("only the root module may override rules_fips source pins")
            _validate_override(tag)
            if tag.name in overrides:
                fail("source %s was overridden more than once" % tag.name)
            overrides[tag.name] = tag

    for name, default in _DEFAULT_SOURCES.items():
        source = overrides.get(name, default)
        http_archive(
            name = name,
            build_file_content = (
                _SYSROOT_BUILD
                if name.endswith("_sysroot")
                else _OTP_SOURCE_BUILD if name == "otp_src" else _SOURCE_BUILD
            ),
            canonical_id = "rules_fips:%s:%s" % (name, source.sha256),
            patch_cmds = (
                ["find . -type d -empty -print | LC_ALL=C sort > rules_fips_empty_dirs.txt"]
                if name == "otp_src"
                else []
            ),
            sha256 = source.sha256,
            strip_prefix = source.strip_prefix,
            type = "tar.xz" if name.endswith("_sysroot") or name == "boringssl_src" else "",
            urls = source.urls,
        )

fips_sources = module_extension(
    implementation = _fips_sources_impl,
    tag_classes = {"source": _source},
)
