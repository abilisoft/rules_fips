"""Bzlmod extension that fetches exact, integrity-pinned FIPS build inputs."""

load("//fips:repositories.bzl", "validate_extracted_tree", "validate_relative_path", "validate_sha256")
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

_ZLIB_BUILD = """
load("@rules_cc//cc:defs.bzl", "cc_binary")

package(default_visibility = ["//visibility:public"])

cc_binary(
    name = "libz.so.1",
    additional_linker_inputs = ["zlib.map"],
    srcs = glob(["*.h"]) + [
        "adler32.c",
        "compress.c",
        "crc32.c",
        "deflate.c",
        "gzclose.c",
        "gzlib.c",
        "gzread.c",
        "gzwrite.c",
        "infback.c",
        "inffast.c",
        "inflate.c",
        "inftrees.c",
        "trees.c",
        "uncompr.c",
        "zutil.c",
    ],
    copts = ["-fPIC"],
    local_defines = ["HAVE_UNISTD_H"],
    linkopts = [
        "-nostdlib++",
        "-Wl,-soname,libz.so.1",
        "-Wl,--version-script,$(location zlib.map)",
    ],
    linkshared = True,
)

exports_files(["LICENSE"])
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

exports_files([
    "usr/include/stdio.h",
    "usr/lib/libssp_nonshared.a",
])
"""

_APK_TOOLCHAIN_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "compiler_builtins",
    srcs = glob(
        ["usr/lib/llvm22/lib/clang/22/lib/*/libclang_rt.builtins-*.a"],
        exclude = ["usr/lib/llvm22/lib/clang/22/lib/linux/**"],
    ),
)

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

_APK_BASH_BUILD = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "runtime",
    srcs = glob(
        ["**"],
        exclude = [
            ".PKGINFO",
            ".SIGN.*",
            "BUILD.bazel",
        ],
    ),
)

exports_files(["bin/bash"])
"""

_APK_SYSROOTS = {
    "musl_amd64_sysroot": [
        ("musl-1.2.6-r2", "573712e2f49c15bfc20a2699f204acdfc74c772722b15e7353d768057fae0e71"),
        ("musl-dev-1.2.6-r2", "6831e8b9e4821dae2c9121f0641f81e543f4ac27c03144c4876980ee84e6988f"),
    ],
    "musl_arm64_sysroot": [
        ("musl-1.2.6-r2", "5e9674b7f41152fe2119093b5cb4c13eaaadb19c2d5422b2d7267913e663ee6e"),
        ("musl-dev-1.2.6-r2", "ca72b84f4eb3c36bbbec04d919eb10159d414c7a43413cc2253841d301fa9486"),
    ],
}

_APK_EXEC_TOOLCHAINS = {
    "fips_llvm_musl_amd64": [
        ("binutils-2.45.1-r1", "9bd1cac7acb87fde3a89a75a524e4f2eeb994d9b3e0aa175a091d83e1d97f466"),
        ("clang22-22.1.8-r0", "567059b3da3fcac554012143a67268cc14ed0122f15c76b5439dd655f074cc62"),
        ("clang22-headers-22.1.8-r0", "5fe1814ec6548850f0e3bbcfa49e2e579b1e0181dd435a2ee437f71977a39400"),
        ("clang22-libs-22.1.8-r0", "f54f9d903e8bbd2ae496b15e74cb671a4c9ac4242c253d25696359f619309ede"),
        ("compiler-rt-22.1.8-r0", "54aef124308d63bf26463293e25045be5449252c0e031ae340966d597fb61d0f"),
        ("jansson-2.15.0-r0", "cfe4ec8ea9b2136bb0c61770c36d2b635b606f2ac2039837a4866003a980d397"),
        ("libffi-3.5.2-r1", "0ab19290ba2a4aea64613c16b9744853363cbd7a61159860eaf4bd255d470f56"),
        ("libgcc-15.2.0-r8", "1be03f36320cd9ccef3be14d82b8e2839cce0754425c2e96bc57e9bf2f0c6b35"),
        ("libstdc++-15.2.0-r8", "2650ea7696e541bd7407803db69250855fbc1f4d97a8f05fd76520f404e502e5"),
        ("libxml2-2.13.9-r2", "4b2f986159c659f014b942fe8a5d70c67af475153ca826c3dd53389eea46a300"),
        ("lld22-22.1.8-r0", "01194a5d4ef62d152c8737329f8553846f4566b81406031049f5b7e9ee14b5cf"),
        ("lld22-libs-22.1.8-r0", "0dc5d7e41edefcd672e1d3fff3a074db790efd04f24cf7c138e1b711dd5da479"),
        ("llvm22-libs-22.1.8-r1", "68b8aaf30be477d3e315a3c678c4d46be222cdf8f055be462278576dfea184e4"),
        ("llvm22-linker-tools-22.1.8-r1", "38455546ff46ded38b074e67d8e1025ecd3e2e7b415613b5e7e97dfa94136703"),
        ("llvm22-22.1.8-r1", "37e1ce390c78f2a58cdd32e936106c4d0d5dfb144745d0d822bde869a278fed8"),
        ("musl-1.2.6-r2", "2aed6644a1332a63ee8873cc5b83e8c358bc6be45a7e16de9c9042e86cf30157"),
        ("scudo-malloc-22.1.8-r0", "2ab7af7c4c98113c25d9060dba4e12792661a7cf3286a848e6d1aac49c377bb6"),
        ("xz-libs-5.8.3-r0", "95162110d7b67e3e2fd243fa4a43f75170a9c4839c47f86bb5e34340a6dfe930"),
        ("zlib-1.3.2-r0", "6e5dd88eb04341f673a40977a2d36bbe825ac772edddd2951192dcff76b9c49e"),
        ("zstd-libs-1.5.7-r2", "5025e2207b44a131f1b2262761187d88500829c2171d566d37a1225246fe542e"),
    ],
    "fips_llvm_musl_arm64": [
        ("binutils-2.45.1-r1", "eb330a90d1e483574698afbaa010c35b8001376b6e11993accd41a1725bb0521"),
        ("clang22-22.1.8-r0", "248c3fb7827fe591a5bf28ba0d567cce235c1395e49d35108eed7892c6c51f53"),
        ("clang22-headers-22.1.8-r0", "9b646282d9c66266a45bd53ac97d79a5d5aaccfe08454ea11800fed2f01114cf"),
        ("clang22-libs-22.1.8-r0", "27f54a9838e012523b0b42a6b398c5af55fde571d4f4e06c8e1e4ec29fb67747"),
        ("compiler-rt-22.1.8-r0", "e34e80b588ed96d5552fdd58b6adeb112e1c2f1f5dffb9ea1f84fbf8043f85a2"),
        ("jansson-2.15.0-r0", "3fcce6a601e64cf5b2c304eb26b281ef0ee7e1bd65f216d9151e86485d03acc3"),
        ("libffi-3.5.2-r1", "bff86f6c3fc29e87fb8741b6a05602e6268a7f8cbefa48ec53d6f7fcfd00ff02"),
        ("libgcc-15.2.0-r8", "dd0d4ca96d24d1e0e694b735a2fed8545362835ba84d287a75865f6afd91f3e0"),
        ("libstdc++-15.2.0-r8", "943e067e9ae9374cb4fc1f2864eb4f31995485e9a320d6be6ba4dd56093cdece"),
        ("libxml2-2.13.9-r2", "27c1a195517714c358c9f8c8dd33ec5d0fcc2b47f44c638a487c2a185e0b00af"),
        ("lld22-22.1.8-r0", "06b36012563bb8e8f2a13bc80be9ac87dac96b14bd330b7084bb8896e8458f08"),
        ("lld22-libs-22.1.8-r0", "44031121030d1b32fa878f2c80b5cdb3f067d1ab771df388830150837506b6c6"),
        ("llvm22-libs-22.1.8-r1", "d8035728913a22671e3bc2eecb64d9a9f79e847126b754aef1d90f50552a816c"),
        ("llvm22-linker-tools-22.1.8-r1", "aa327ce75d1908aa31b435db1d8e6f72c57151cca2d69c5a61bb0bafc9e800ff"),
        ("llvm22-22.1.8-r1", "0ac5f364ff2e7a1e7a9e8d607ef55f027e8c151ad42d37488400c58843a65ba0"),
        ("musl-1.2.6-r2", "c6e74d765f7029fdc4389340181616eb834a6e692b16144c0ca8f8d0662578b3"),
        ("scudo-malloc-22.1.8-r0", "14b579c7677a7fd35b29781b94cba1d5e83aed20ad86d0687ca4386dd082a69c"),
        ("xz-libs-5.8.3-r0", "b139f4c3747b46dd1461592cfe4a0d3e6daf010d7376691092968d6f69cb1612"),
        ("zlib-1.3.2-r0", "1d354ed1ef4e7bd9f6459b56a5e0d5c81ec78788d165b6a459f0b41ff3f4c037"),
        ("zstd-libs-1.5.7-r2", "67f0803cc07bad0dd866d21fdaca1fa742b541a4e5e96e0159bd8b0054d348ac"),
    ],
}

_APK_EXEC_TOOLS = {
    "fips_bash_exec_amd64": struct(
        arch = "x86_64",
        branch = "v3.24",
        build_file_content = _APK_BASH_BUILD,
        packages = [
            ("bash-5.3.9-r1", "4ad962f26fb3c68365171233fe61e3c51bbee1cab35e8dc661198233daeab0dd"),
            ("readline-8.3.3-r1", "766911ecb986a6c5cf0841a6b556cd1e9dbbf22b3559726de32416486cd15c81"),
            ("libncursesw-6.6_p20260516-r0", "cf8caa8a88bc4ce9d9e395567fefaf9ef7fbd55c50ae6155b35c1b58f3755023"),
            ("ncurses-terminfo-base-6.6_p20260516-r0", "ce83be6d0bd10584a53c3a5868cc1595ce5f0f8e0b621f8f7f70b6144e521fc9"),
        ],
        repository = "main",
    ),
    "fips_bash_exec_arm64": struct(
        arch = "aarch64",
        branch = "v3.24",
        build_file_content = _APK_BASH_BUILD,
        packages = [
            ("bash-5.3.9-r1", "95f4f976bdf2f4ca18ff41c32916eb6d7b12a0dae12504d55d04427460d6542f"),
            ("readline-8.3.3-r1", "9f0ae0923c02b0d6aba62e9173542b65396ba3f0efefcbf087ea32f1120e7b34"),
            ("libncursesw-6.6_p20260516-r0", "51a7aa4b3ec40b144d0801c0544e0a9f62e2a41d04b6067bb5e95786040741c6"),
            ("ncurses-terminfo-base-6.6_p20260516-r0", "e0c546b9461bdce206a90bc720cb69aa4628b5a5b8d908c3e5084e00f28f6a9d"),
        ],
        repository = "main",
    ),
    "fips_qemu_aarch64": struct(
        arch = "x86_64",
        branch = "edge",
        build_file_content = _APK_QEMU_BUILD,
        packages = [
            ("qemu-aarch64-11.0.2-r1", "3b3f92732d706e87bfd31a81186e47b42b50d742e55b13ead2c48043f3c76a26"),
        ],
        repository = "community",
    ),
}

def _validate_strip_prefix(name, strip_prefix):
    validate_relative_path(name, strip_prefix, "strip prefix")

def _source_repo_impl(repository_ctx):
    validate_sha256(repository_ctx.name, repository_ctx.attr.sha256)
    _validate_strip_prefix(repository_ctx.name, repository_ctx.attr.strip_prefix)
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
        type = repository_ctx.attr.archive_type,
        canonical_id = "rules_fips:%s:%s" % (repository_ctx.name, repository_ctx.attr.sha256),
    )
    validate_extracted_tree(repository_ctx)
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

_source_repo = repository_rule(
    implementation = _source_repo_impl,
    attrs = {
        "archive_type": attr.string(),
        "build_file_content": attr.string(mandatory = True),
        "catalog_entry": attr.bool(),
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
        validate_sha256(name, sha256)
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
    validate_extracted_tree(repository_ctx)
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
    "openssl_core_src": OPENSSL_CORE_RELEASES[DEFAULT_OPENSSL_CORE_VERSION],
    "openssl_fips_src": OPENSSL_FIPS_PROVIDER_RELEASES[DEFAULT_OPENSSL_FIPS_PROVIDER_VERSION],
    "musl_src": struct(
        urls = ["https://git.musl-libc.org/cgit/musl/snapshot/musl-b306b16af15c89a04d8e0c55cac2dadbeb39c083.tar.gz"],
        sha256 = "79325f4b37bc827346c45556787b0441f7cacad70a2362484e7e169e072fb7a5",
        strip_prefix = "musl-b306b16af15c89a04d8e0c55cac2dadbeb39c083",
        version = "b306b16af15c89a04d8e0c55cac2dadbeb39c083",
    ),
    "fips_zlib": struct(
        urls = [
            "https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz",
            "https://zlib.net/zlib-1.3.2.tar.gz",
        ],
        sha256 = "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16",
        strip_prefix = "zlib-1.3.2",
        version = "1.3.2",
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
    validate_sha256(tag.name, tag.sha256)
    _validate_strip_prefix(tag.name, tag.strip_prefix)
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
            build_file_content = _ZLIB_BUILD if name == "fips_zlib" else _SOURCE_BUILD,
            catalog_entry = name not in overrides,
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
            arch = "aarch64" if name.endswith("_arm64") else "x86_64",
            branch = "edge",
            build_file_content = _APK_TOOLCHAIN_BUILD,
            packages = ["%s|%s" % package for package in packages],
        )

    for name, tool in _APK_EXEC_TOOLS.items():
        _apk_sysroot_repo(
            name = name,
            arch = tool.arch,
            branch = tool.branch,
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
