"""Bzlmod extension that fetches exact, integrity-pinned FIPS build inputs."""

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

_APK_SYSROOT_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "sysroot",
    srcs = glob(
        ["**"],
        exclude = [
            ".PKGINFO",
            ".SIGN.*",
            "BUILD.bazel",
        ],
    ),
)

exports_files(["usr/include/stdio.h"])
"""

_APK_SYSROOTS = {
    "musl_amd64_sysroot": [
        ("musl-1.2.6-r2", "573712e2f49c15bfc20a2699f204acdfc74c772722b15e7353d768057fae0e71"),
        ("musl-dev-1.2.6-r2", "6831e8b9e4821dae2c9121f0641f81e543f4ac27c03144c4876980ee84e6988f"),
        ("linux-headers-7.0.0-r1", "c4535f3f0dc6fd4d80efa7ff2a7a72a2d3f8dae31e2587c0785cc3243889cdf2"),
        ("clang22-headers-22.1.3-r2", "a987e1e1b7e0c42a1868ca44b703fe07367cbdda4a71675a2517d5f5d0bc86fe"),
        ("libc++-dev-22.1.3-r0", "0d41363e1fbcc8e7472bd7de7edc69c8808b42b5523a85d074e09d29d385cc80"),
        ("libc++-static-22.1.3-r0", "c461faf4fdacf587c6ea624a28febd9555ae049218f1bd484e69b93b0b4c00fd"),
        ("llvm-libunwind-dev-22.1.3-r0", "7dee6480b1f5cb20d4a99b876ad0532a5cc8f814e33b40f043d2977be2b978a7"),
        ("llvm-libunwind-static-22.1.3-r0", "c926bdd674e739f7a268f6374dfab4b159051fdafa5a44c0c74566051ea3fc88"),
        ("compiler-rt-22.1.3-r0", "1775eb9ba0aa9d465820ee7eb6918390973389f1f32b15378a9cc9c554ce5ee2"),
    ],
    "musl_arm64_sysroot": [
        ("musl-1.2.6-r2", "5e9674b7f41152fe2119093b5cb4c13eaaadb19c2d5422b2d7267913e663ee6e"),
        ("musl-dev-1.2.6-r2", "ca72b84f4eb3c36bbbec04d919eb10159d414c7a43413cc2253841d301fa9486"),
        ("linux-headers-7.0.0-r1", "d61656e81116040ebac0bc8d9046a3ba97f01a00ee085809103576e8a437468f"),
        ("clang22-headers-22.1.3-r2", "9740b2bbb74a62270f4014cbbb7fdf50d62914239ec1b5483c86156693dbfac0"),
        ("libc++-dev-22.1.3-r0", "5c5778947019a397b5e7ed7be5fedde6f2ca2c511fe408ca88bf8f14186f6287"),
        ("libc++-static-22.1.3-r0", "1bd9eea3025e81efaead32a454d13e4bcb3615230fb1b2f52d52f518f2dca61e"),
        ("llvm-libunwind-dev-22.1.3-r0", "2a785cbada785b747c8663813f2fe1c1dfd67c0abca1b62186e7b149e6ea2102"),
        ("llvm-libunwind-static-22.1.3-r0", "1c724758cd311a5eb190306475851047052aa4673d6b55001692f7f2ff0fc400"),
        ("compiler-rt-22.1.3-r0", "4339f4d0ea4e3c0825ce164e9b26289af894c852005f1f08dcd17709d1d9def5"),
    ],
}

def _preserve_empty_directories(repository_ctx):
    empty_dirs = []
    pending = [(repository_ctx.path("."), "")]
    for _ in range(256):
        if not pending:
            return sorted(empty_dirs)
        next_directories = []
        for directory, relative in pending:
            entries = directory.readdir(watch = "no")
            if not entries and relative:
                repository_ctx.file(relative + "/.rules_fips_keep", "")
                empty_dirs.append(relative)
                continue
            for entry in entries:
                if entry.is_dir:
                    child = entry.basename if not relative else relative + "/" + entry.basename
                    next_directories.append((entry, child))
        pending = next_directories
    fail("source archive exceeds the supported directory depth")

def _source_repo_impl(repository_ctx):
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
        type = repository_ctx.attr.archive_type,
        canonical_id = "rules_fips:%s:%s" % (repository_ctx.name, repository_ctx.attr.sha256),
    )
    repository_ctx.file("BUILD.bazel", repository_ctx.attr.build_file_content)
    if repository_ctx.attr.preserve_empty_dirs:
        empty_dirs = _preserve_empty_directories(repository_ctx)
        repository_ctx.file(
            "rules_fips_empty_dirs.txt",
            "\n".join(["./" + path for path in empty_dirs]) + "\n",
        )

_source_repo = repository_rule(
    implementation = _source_repo_impl,
    attrs = {
        "archive_type": attr.string(),
        "build_file_content": attr.string(mandatory = True),
        "preserve_empty_dirs": attr.bool(),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "urls": attr.string_list(mandatory = True),
    },
)

def _apk_sysroot_repo_impl(repository_ctx):
    arch = repository_ctx.attr.arch
    for package in repository_ctx.attr.packages:
        name, sha256 = package.split("|")
        repository_ctx.download_and_extract(
            url = "https://dl-cdn.alpinelinux.org/alpine/v3.24/main/%s/%s.apk" % (arch, name),
            sha256 = sha256,
            type = "tar.gz",
            canonical_id = "rules_fips:alpine-v3.24:%s:%s" % (arch, sha256),
        )
    repository_ctx.file("BUILD.bazel", _APK_SYSROOT_BUILD)

_apk_sysroot_repo = repository_rule(
    implementation = _apk_sysroot_repo_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "packages": attr.string_list(mandatory = True),
    },
)

_DEFAULT_SOURCES = {
    "boringssl_src": struct(
        urls = [
            "https://github.com/google/boringssl/archive/a430310d6563c0734ddafca7731570dfb683dc19.tar.gz",
        ],
        sha256 = "868930e812afa1967bed57f3cefcadc8a32e1d2207c76b934125189436179346",
        strip_prefix = "boringssl-a430310d6563c0734ddafca7731570dfb683dc19",
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
        _source_repo(
            name = name,
            build_file_content = (
                _SYSROOT_BUILD
                if name.endswith("_sysroot")
                else _OTP_SOURCE_BUILD if name == "otp_src" else _SOURCE_BUILD
            ),
            preserve_empty_dirs = name == "otp_src",
            sha256 = source.sha256,
            strip_prefix = source.strip_prefix,
            archive_type = "tar.xz" if name.endswith("_sysroot") else "",
            urls = source.urls,
        )

    for name, packages in _APK_SYSROOTS.items():
        _apk_sysroot_repo(
            name = name,
            arch = "x86_64" if name == "musl_amd64_sysroot" else "aarch64",
            packages = ["%s|%s" % package for package in packages],
        )

fips_sources = module_extension(
    implementation = _fips_sources_impl,
    tag_classes = {"source": _source},
)
