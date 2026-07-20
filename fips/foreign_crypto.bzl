"""rules_foreign_cc builds with certificate references and runtime evidence."""

load("@rules_foreign_cc//foreign_cc:defs.bzl", "configure_make")
load("//fips:providers.bzl", "FipsCryptoInfo")
load("//fips:source_versions.bzl", "OPENSSL_CORE_SOURCE", "OPENSSL_FIPS_CERTIFICATE_REFERENCE", "OPENSSL_FIPS_SOURCE")

_TOOLCHAIN_TYPE = Label("//fips:toolchain_type")
_TARGET_AMD64 = Label("//fips/platforms:target_amd64")
_TARGET_ARM64 = Label("//fips/platforms:target_arm64")
_FOREIGN_PERL = Label("//fips/toolchains:foreign_perl")
_FOREIGN_TOOLBOX = Label("//fips/toolchains:foreign_toolbox")
_FOREIGN_TOOLBOX_SHELL = Label("//fips/toolchains:foreign_toolbox_shell")
_LLVM_MUSL = Label("//fips/toolchains:llvm_musl")
_LLVM_TOOLS = {
    name: Label("//fips/toolchains:llvm_musl/bin/{}".format(name))
    for name in [
        "ar",
        "clang",
        "clang++",
        "ld.lld",
        "nm",
        "objcopy",
        "objdump",
        "ranlib",
        "readelf",
        "strip",
    ]
}
_MUSL_AMD64_SYSROOT = Label("@musl_amd64_sysroot//:sysroot")
_MUSL_AMD64_MARKER = Label("@musl_amd64_sysroot//:usr/include/stdio.h")
_MUSL_ARM64_SYSROOT = Label("@musl_arm64_sysroot//:sysroot")
_MUSL_ARM64_MARKER = Label("@musl_arm64_sysroot//:usr/include/stdio.h")
_OPENSSL_CORE_SOURCE = Label("@openssl_core_src//:srcs")
_OPENSSL_FIPS_SOURCE = Label("@openssl_fips_src//:srcs")

def _llvm_tool(name):
    return "$(execpath {})".format(_LLVM_TOOLS[name])

def _toolbox_shell():
    return "$(execpath {})".format(_FOREIGN_TOOLBOX_SHELL)

def _foreign_path():
    return ":".join([
        "$$(dirname %s)" % _toolbox_shell(),
        "$$(dirname $(execpath {}))".format(_FOREIGN_PERL),
    ])

def _file_named(files, basename):
    for file in files:
        if file.basename == basename:
            return file
    fail("rules_foreign_cc output did not contain %s" % basename)

def _directory_named(files, basename):
    for file in files:
        if file.is_directory and file.basename == basename:
            return file
    fail("rules_foreign_cc output did not contain directory %s" % basename)

def _sysroot(marker):
    return "$$(dirname $$(dirname $$(dirname $(execpath %s))))" % marker

def _openssl_env(marker, triplet):
    sysroot = _sysroot(marker)
    resource_dir = sysroot + "/usr/lib/llvm22/lib/clang/22"
    compile_flags = " ".join([
        "--target=" + triplet,
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-B" + sysroot + "/usr/lib/",
        "-O2",
        "-fPIC",
    ])
    link_flags = " ".join([
        "--target=" + triplet,
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-B" + sysroot + "/usr/lib/",
        "--rtlib=compiler-rt",
        "--unwindlib=libunwind",
        "-fuse-ld=" + _llvm_tool("ld.lld"),
        "-Wl,-S",
        "-Wl,-z,relro,-z,now",
        "-Wl,--dynamic-linker=/proc/self/cwd/lib/ld-musl.so.1",
        "-Wl,-rpath,/proc/self/cwd/lib",
    ])
    return {
        "AR": _llvm_tool("ar"),
        "CC": _llvm_tool("clang"),
        "CFLAGS": compile_flags,
        "CONFIG_SHELL": _toolbox_shell(),
        "CXX": _llvm_tool("clang++"),
        "GOCACHE": "$$BUILD_TMPDIR/gocache",
        "HOME": "$$BUILD_TMPDIR",
        "LD": _llvm_tool("ld.lld"),
        "LDFLAGS": link_flags,
        "NM": _llvm_tool("nm"),
        "OBJCOPY": _llvm_tool("objcopy"),
        "OBJDUMP": _llvm_tool("objdump"),
        "PERL": "$(execpath {})".format(_FOREIGN_PERL),
        "PATH": _foreign_path(),
        "READELF": _llvm_tool("readelf"),
        "SOURCE_DATE_EPOCH": "0",
        "SHELL": _toolbox_shell(),
        "STRIP": _llvm_tool("strip"),
        "TMPDIR": "$$BUILD_TMPDIR",
    }

def _openssl_finalize_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    core_files = ctx.attr.core[DefaultInfo].files.to_list()
    provider_files = ctx.attr.provider[DefaultInfo].files.to_list()
    libcrypto = _file_named(core_files, "libcrypto.a")
    libssl = _file_named(core_files, "libssl.a")
    include_dir = _directory_named(core_files, "include")
    openssl_bin = _file_named(core_files, "openssl")
    fips_module = _file_named(provider_files, "fips.so")
    manifest = ctx.actions.declare_file(ctx.label.name + "/FIPS_BUILD.json")
    core_license = ctx.actions.declare_file(ctx.label.name + "/licenses/openssl-core-LICENSE.txt")
    fips_license = ctx.actions.declare_file(ctx.label.name + "/licenses/openssl-fips-provider-LICENSE.txt")

    ctx.actions.symlink(output = core_license, target_file = ctx.file.core_license)
    ctx.actions.symlink(output = fips_license, target_file = ctx.file.fips_license)

    ctx.actions.run(
        arguments = [
            "openssl",
            openssl_bin.path,
            fips_module.path,
            ctx.file.openssl_config.path,
            libcrypto.path,
            libssl.path,
            manifest.path,
            platform.arch,
            platform.musl_loader_path,
            platform.sysroot_path,
            platform.llvm_readelf,
            platform.qemu_aarch64_file.path if platform.arch == "arm64" else "-",
            OPENSSL_FIPS_CERTIFICATE_REFERENCE,
            OPENSSL_FIPS_SOURCE.version,
            OPENSSL_FIPS_SOURCE.sha256,
            OPENSSL_CORE_SOURCE.version,
            OPENSSL_CORE_SOURCE.sha256,
        ],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.executable.validator,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [
                ctx.file.core_license,
                ctx.file.fips_license,
                ctx.file.openssl_config,
                fips_module,
                include_dir,
                libcrypto,
                libssl,
                openssl_bin,
            ],
            transitive = [
                platform.clang_files,
                platform.qemu_aarch64_files,
                platform.sysroot_files,
            ],
        ),
        mnemonic = "OpenSslFipsFinalize",
        outputs = [manifest],
        progress_message = "Checking rules_foreign_cc OpenSSL FIPS outputs for %s" % platform.arch,
    )

    files = depset([
        libcrypto,
        libssl,
        include_dir,
        openssl_bin,
        fips_module,
        ctx.file.openssl_config,
        core_license,
        fips_license,
        manifest,
        platform.musl_libc_file,
        platform.musl_license_file,
        platform.musl_loader_file,
    ])
    return [
        DefaultInfo(files = files),
        FipsCryptoInfo(
            backend = "openssl",
            certificate = OPENSSL_FIPS_CERTIFICATE_REFERENCE,
            include_dir = include_dir,
            manifest = manifest,
            module_name = "OpenSSL FIPS Provider",
            module_version = OPENSSL_FIPS_SOURCE.version,
            runtime_files = depset([
                openssl_bin,
                fips_module,
                ctx.file.openssl_config,
                core_license,
                fips_license,
                platform.musl_libc_file,
                platform.musl_license_file,
                platform.musl_loader_file,
            ]),
            service_indicator = "provider-properties-fips=yes",
            static_libs = depset([libssl, libcrypto], order = "preorder"),
        ),
    ]

_openssl_finalize = rule(
    implementation = _openssl_finalize_impl,
    attrs = {
        "core": attr.label(mandatory = True),
        "core_license": attr.label(
            allow_single_file = True,
            default = Label("@openssl_core_src//:LICENSE.txt"),
        ),
        "fips_license": attr.label(
            allow_single_file = True,
            default = Label("@openssl_fips_src//:LICENSE.txt"),
        ),
        "openssl_config": attr.label(
            allow_single_file = [".cnf"],
            default = Label("//runtime:openssl-fips.cnf"),
        ),
        "provider": attr.label(mandatory = True),
        "validator": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = Label("//fips/private:fips_artifact_validator"),
            executable = True,
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def _openssl_foreign_build_data():
    return [
        _FOREIGN_TOOLBOX,
        _FOREIGN_TOOLBOX_SHELL,
        _LLVM_MUSL,
        _LLVM_TOOLS["ar"],
        _LLVM_TOOLS["clang"],
        _LLVM_TOOLS["clang++"],
        _LLVM_TOOLS["ld.lld"],
        _LLVM_TOOLS["nm"],
        _LLVM_TOOLS["objcopy"],
        _LLVM_TOOLS["objdump"],
        _LLVM_TOOLS["ranlib"],
        _LLVM_TOOLS["readelf"],
        _LLVM_TOOLS["strip"],
        _FOREIGN_PERL,
    ] + select({
        _TARGET_AMD64: [_MUSL_AMD64_SYSROOT, _MUSL_AMD64_MARKER],
        _TARGET_ARM64: [_MUSL_ARM64_SYSROOT, _MUSL_ARM64_MARKER],
    })

def _openssl_selected_env():
    return select({
        _TARGET_AMD64: _openssl_env(
            _MUSL_AMD64_MARKER,
            "x86_64-alpine-linux-musl",
        ),
        _TARGET_ARM64: _openssl_env(
            _MUSL_ARM64_MARKER,
            "aarch64-alpine-linux-musl",
        ),
    })

def _openssl_target():
    return select({
        _TARGET_AMD64: ["linux-x86_64"],
        _TARGET_ARM64: ["linux-aarch64"],
    })

def openssl_fips(name, visibility = None, tags = None):
    """Builds the OpenSSL core and certificate-referenced provider.

    Args:
      name: Crypto target name.
      visibility: Optional target visibility.
      tags: Optional tags applied to generated targets.
    """
    core_name = name + "_core_foreign"
    provider_name = name + "_provider_foreign"
    common = {}
    if tags != None:
        common["tags"] = tags

    configure_make(
        name = provider_name,
        args = [
            "-s",
            "-j8",
            "RANLIB=$$EXT_BUILD_ROOT$$/" + _llvm_tool("ranlib"),
        ],
        build_data = _openssl_foreign_build_data(),
        configure_command = "Configure",
        configure_options = _openssl_target() + [
            "--libdir=lib",
            "enable-fips",
            "no-tests",
        ],
        configure_prefix = "$(execpath {})".format(_FOREIGN_PERL),
        env = _openssl_selected_env(),
        lib_source = _OPENSSL_FIPS_SOURCE,
        out_include_dir = "",
        out_lib_dir = "lib/ossl-modules",
        out_shared_libs = ["fips.so"],
        targets = ["", "install_fips"],
        **common
    )

    configure_make(
        name = core_name,
        args = [
            "-s",
            "-j8",
            "RANLIB=$$EXT_BUILD_ROOT$$/" + _llvm_tool("ranlib"),
        ],
        build_data = _openssl_foreign_build_data(),
        configure_command = "Configure",
        configure_options = _openssl_target() + [
            "--libdir=lib",
            "no-shared",
            "no-tests",
        ],
        configure_prefix = "$(execpath {})".format(_FOREIGN_PERL),
        env = _openssl_selected_env(),
        lib_source = _OPENSSL_CORE_SOURCE,
        out_binaries = ["openssl"],
        out_static_libs = ["libcrypto.a", "libssl.a"],
        targets = ["build_sw", "install_sw"],
        **common
    )

    final_args = dict(common)
    final_args.update({
        "core": ":" + core_name,
        "provider": ":" + provider_name,
    })
    if visibility != None:
        final_args["visibility"] = visibility
    _openssl_finalize(
        name = name,
        **final_args
    )
