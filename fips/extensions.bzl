"""Bzlmod extension that fetches exact, integrity-pinned FIPS build inputs."""

load(
    "//fips:versions.bzl",
    "DEFAULT_OPENSSL_CORE_VERSION",
    "DEFAULT_OPENSSL_FIPS_PROVIDER_VERSION",
    "OPENSSL_CORE_RELEASES",
    "OPENSSL_FIPS_PROVIDER_RELEASES",
)

_SOURCE_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "srcs",
    srcs = glob(["**"], exclude = [".git/**"]),
)

exports_files(glob(["*"]))
"""

_OTP_SOURCE_BUILD = _SOURCE_BUILD

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

_APK_TOOLCHAIN_BUILD = """
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

exports_files(["usr/bin/clang"])
"""

_APK_QEMU_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(
        ["**"],
        exclude = [
            ".PKGINFO",
            ".SIGN.*",
            "BUILD.bazel",
        ],
    ),
)

exports_files(["usr/bin/qemu-aarch64"])
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

_APK_EXEC_TOOLCHAINS = {
    "fips_llvm_musl_amd64": [
        ("binutils-2.45.1-r1", "9bd1cac7acb87fde3a89a75a524e4f2eeb994d9b3e0aa175a091d83e1d97f466"),
        ("clang22-22.1.8-r0", "567059b3da3fcac554012143a67268cc14ed0122f15c76b5439dd655f074cc62"),
        ("clang22-libs-22.1.8-r0", "f54f9d903e8bbd2ae496b15e74cb671a4c9ac4242c253d25696359f619309ede"),
        ("jansson-2.15.0-r0", "cfe4ec8ea9b2136bb0c61770c36d2b635b606f2ac2039837a4866003a980d397"),
        ("libffi-3.5.2-r1", "0ab19290ba2a4aea64613c16b9744853363cbd7a61159860eaf4bd255d470f56"),
        ("libgcc-15.2.0-r8", "1be03f36320cd9ccef3be14d82b8e2839cce0754425c2e96bc57e9bf2f0c6b35"),
        ("libstdc++-15.2.0-r8", "2650ea7696e541bd7407803db69250855fbc1f4d97a8f05fd76520f404e502e5"),
        ("libxml2-2.13.9-r2", "4b2f986159c659f014b942fe8a5d70c67af475153ca826c3dd53389eea46a300"),
        ("lld22-22.1.8-r0", "01194a5d4ef62d152c8737329f8553846f4566b81406031049f5b7e9ee14b5cf"),
        ("lld22-libs-22.1.8-r0", "0dc5d7e41edefcd672e1d3fff3a074db790efd04f24cf7c138e1b711dd5da479"),
        ("llvm22-libs-22.1.8-r1", "68b8aaf30be477d3e315a3c678c4d46be222cdf8f055be462278576dfea184e4"),
        ("llvm22-linker-tools-22.1.8-r1", "38455546ff46ded38b074e67d8e1025ecd3e2e7b415613b5e7e97dfa94136703"),
        ("musl-1.2.6-r2", "2aed6644a1332a63ee8873cc5b83e8c358bc6be45a7e16de9c9042e86cf30157"),
        ("scudo-malloc-22.1.8-r0", "2ab7af7c4c98113c25d9060dba4e12792661a7cf3286a848e6d1aac49c377bb6"),
        ("xz-libs-5.8.3-r0", "95162110d7b67e3e2fd243fa4a43f75170a9c4839c47f86bb5e34340a6dfe930"),
        ("zlib-1.3.2-r0", "6e5dd88eb04341f673a40977a2d36bbe825ac772edddd2951192dcff76b9c49e"),
        ("zstd-libs-1.5.7-r2", "5025e2207b44a131f1b2262761187d88500829c2171d566d37a1225246fe542e"),
    ],
}

_APK_EXEC_TOOLS = {
    "fips_qemu_aarch64": struct(
        build_file_content = _APK_QEMU_BUILD,
        packages = [
            ("qemu-aarch64-11.0.2-r1", "3b3f92732d706e87bfd31a81186e47b42b50d742e55b13ead2c48043f3c76a26"),
        ],
        repository = "community",
    ),
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
    repository_ctx.file(
        "rules_fips_source.bzl",
        """SOURCE = struct(
    catalog_entry = %r,
    version = %r,
    sha256 = %r,
    strip_prefix = %r,
    urls = %r,
)
""" % (
            repository_ctx.attr.catalog_entry,
            repository_ctx.attr.version,
            repository_ctx.attr.sha256,
            repository_ctx.attr.strip_prefix,
            repository_ctx.attr.urls,
        ),
    )
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
        "catalog_entry": attr.bool(),
        "preserve_empty_dirs": attr.bool(),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "urls": attr.string_list(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

def _apk_sysroot_repo_impl(repository_ctx):
    arch = repository_ctx.attr.arch
    for package in repository_ctx.attr.packages:
        name, sha256 = package.split("|")
        repository_ctx.download_and_extract(
            url = "https://dl-cdn.alpinelinux.org/alpine/%s/%s/%s/%s.apk" % (
                repository_ctx.attr.branch,
                repository_ctx.attr.repository,
                arch,
                name,
            ),
            sha256 = sha256,
            type = "tar.gz",
            canonical_id = "rules_fips:alpine-%s:%s:%s" % (repository_ctx.attr.branch, arch, sha256),
        )
    repository_ctx.file(
        "BUILD.bazel",
        repository_ctx.attr.build_file_content,
    )

_apk_sysroot_repo = repository_rule(
    implementation = _apk_sysroot_repo_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "branch": attr.string(default = "v3.24"),
        "build_file_content": attr.string(mandatory = True),
        "packages": attr.string_list(mandatory = True),
        "repository": attr.string(default = "main"),
    },
)

_DEFAULT_SOURCES = {
    "elixir_src": struct(
        urls = ["https://github.com/elixir-lang/elixir/archive/refs/tags/v1.20.2.tar.gz"],
        sha256 = "1a25bbf9a9016651fc332eecc02bb9681d0b8e722c2e256e73ddb88fbce6e6b0",
        strip_prefix = "elixir-1.20.2",
        version = "1.20.2",
    ),
    "openssl_core_src": OPENSSL_CORE_RELEASES[DEFAULT_OPENSSL_CORE_VERSION],
    "openssl_fips_src": OPENSSL_FIPS_PROVIDER_RELEASES[DEFAULT_OPENSSL_FIPS_PROVIDER_VERSION],
    "otp_src": struct(
        urls = ["https://github.com/erlang/otp/archive/refs/tags/OTP-29.0.3.tar.gz"],
        sha256 = "edef13778a449490bc183134e442a955b134d69c56075d97765d8d4951d8d2bb",
        strip_prefix = "otp-OTP-29.0.3",
        version = "29.0.3",
    ),
    "musl_src": struct(
        urls = ["https://git.musl-libc.org/cgit/musl/snapshot/musl-b306b16af15c89a04d8e0c55cac2dadbeb39c083.tar.gz"],
        sha256 = "79325f4b37bc827346c45556787b0441f7cacad70a2362484e7e169e072fb7a5",
        strip_prefix = "musl-b306b16af15c89a04d8e0c55cac2dadbeb39c083",
        version = "b306b16af15c89a04d8e0c55cac2dadbeb39c083",
    ),
}

_source = tag_class(attrs = {
    "name": attr.string(mandatory = True),
    "sha256": attr.string(mandatory = True),
    "strip_prefix": attr.string(mandatory = True),
    "urls": attr.string_list(mandatory = True),
    "version": attr.string(mandatory = True),
})

_openssl = tag_class(attrs = {
    "core_version": attr.string(default = DEFAULT_OPENSSL_CORE_VERSION),
    "fips_provider_version": attr.string(default = DEFAULT_OPENSSL_FIPS_PROVIDER_VERSION),
})

def _validate_override(tag):
    if tag.name not in _DEFAULT_SOURCES:
        fail("unknown rules_fips source override: %s" % tag.name)
    if len(tag.sha256) != 64:
        fail("source %s must use a 64-character SHA-256 digest" % tag.name)
    if not tag.version:
        fail("source %s must provide its semantic version or immutable revision" % tag.name)
    if not tag.urls:
        fail("source %s must provide at least one URL" % tag.name)
    for url in tag.urls:
        if not url.startswith("https://"):
            fail("source %s URL must use HTTPS: %s" % (tag.name, url))

def _validate_openssl_selection(tag):
    if tag.core_version not in OPENSSL_CORE_RELEASES:
        fail("OpenSSL core %s is not in the tested catalog; use a source override with an exact URL and SHA-256" % tag.core_version)
    if tag.fips_provider_version not in OPENSSL_FIPS_PROVIDER_RELEASES:
        fail("OpenSSL FIPS provider %s is not in the tested catalog; use a source override with an exact URL and SHA-256" % tag.fips_provider_version)

def _fips_sources_impl(module_ctx):
    overrides = {}
    openssl_selection = None
    for mod in module_ctx.modules:
        for tag in mod.tags.source:
            if not mod.is_root:
                fail("only the root module may override rules_fips source pins")
            _validate_override(tag)
            if tag.name in overrides:
                fail("source %s was overridden more than once" % tag.name)
            overrides[tag.name] = tag
        for tag in mod.tags.openssl:
            if not mod.is_root:
                fail("only the root module may select an OpenSSL catalog entry")
            if openssl_selection != None:
                fail("OpenSSL catalog entry was selected more than once")
            _validate_openssl_selection(tag)
            openssl_selection = tag

    sources = dict(_DEFAULT_SOURCES)
    if openssl_selection != None:
        for name in ["openssl_core_src", "openssl_fips_src"]:
            if name in overrides:
                fail("OpenSSL catalog selection cannot be combined with a %s source override" % name)
        sources["openssl_core_src"] = OPENSSL_CORE_RELEASES[openssl_selection.core_version]
        sources["openssl_fips_src"] = OPENSSL_FIPS_PROVIDER_RELEASES[openssl_selection.fips_provider_version]

    for name, default in sources.items():
        source = overrides.get(name, default)
        _source_repo(
            name = name,
            build_file_content = _OTP_SOURCE_BUILD if name == "otp_src" else _SOURCE_BUILD,
            catalog_entry = name not in overrides,
            preserve_empty_dirs = name == "otp_src",
            sha256 = source.sha256,
            strip_prefix = source.strip_prefix,
            archive_type = "",
            urls = source.urls,
            version = source.version,
        )

    for name, packages in _APK_SYSROOTS.items():
        _apk_sysroot_repo(
            name = name,
            arch = "x86_64" if name == "musl_amd64_sysroot" else "aarch64",
            build_file_content = _APK_SYSROOT_BUILD,
            packages = ["%s|%s" % package for package in packages],
        )

    for name, packages in _APK_EXEC_TOOLCHAINS.items():
        _apk_sysroot_repo(
            name = name,
            arch = "x86_64",
            branch = "edge",
            build_file_content = _APK_TOOLCHAIN_BUILD,
            packages = ["%s|%s" % package for package in packages],
        )

    for name, tool in _APK_EXEC_TOOLS.items():
        _apk_sysroot_repo(
            name = name,
            arch = "x86_64",
            branch = "edge",
            build_file_content = tool.build_file_content,
            packages = ["%s|%s" % package for package in tool.packages],
            repository = tool.repository,
        )

fips_sources = module_extension(
    implementation = _fips_sources_impl,
    tag_classes = {
        "openssl": _openssl,
        "source": _source,
    },
)
