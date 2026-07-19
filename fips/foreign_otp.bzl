"""rules_foreign_cc-backed OTP bootstrap and target builds."""

load("@rules_foreign_cc//foreign_cc:defs.bzl", "configure_make")
load(
    "//fips:providers.bzl",
    "FipsCryptoInfo",
    "FipsOtpBootstrapInfo",
    "FipsOtpRuntimeInfo",
)
load("//fips:source_versions.bzl", "OTP_SOURCE")

_TOOLCHAIN_TYPE = "//fips:toolchain_type"
_TARGET_AMD64 = "//fips/platforms:target_amd64"
_TARGET_ARM64 = "//fips/platforms:target_arm64"

def _llvm_tool(name):
    return "$(execpath //fips/toolchains:llvm_musl/bin/%s)" % name

def _toolbox_shell():
    return "$(execpath //fips/toolchains:foreign_toolbox_shell)"

def _foreign_path(prefix = None):
    paths = []
    if prefix != None:
        paths.append(prefix)
    paths.extend([
        "$$(dirname %s)" % _toolbox_shell(),
        "$$(dirname $(execpath //fips/toolchains:foreign_perl))",
        "/bin",
    ])
    return ":".join(paths)

def _llvm_build_data():
    return [
        "//fips/toolchains:foreign_perl",
        "//fips/toolchains:foreign_toolbox",
        "//fips/toolchains:foreign_toolbox_shell",
        "//fips/toolchains:llvm_musl",
        "//fips/toolchains:llvm_musl/bin/ar",
        "//fips/toolchains:llvm_musl/bin/clang",
        "//fips/toolchains:llvm_musl/bin/clang++",
        "//fips/toolchains:llvm_musl/bin/ld.lld",
        "//fips/toolchains:llvm_musl/bin/nm",
        "//fips/toolchains:llvm_musl/bin/objcopy",
        "//fips/toolchains:llvm_musl/bin/objdump",
        "//fips/toolchains:llvm_musl/bin/ranlib",
        "//fips/toolchains:llvm_musl/bin/readelf",
        "//fips/toolchains:llvm_musl/bin/strip",
    ]

def _directory_named(files, basename):
    for file in files:
        if file.is_directory and file.basename == basename:
            return file
    fail("rules_foreign_cc output did not contain directory %s" % basename)

def _file_named(files, basename, required = True):
    for file in files:
        if file.basename == basename:
            return file
    if required:
        fail("required FIPS input %s was not provided" % basename)
    return None

def _sysroot(marker):
    return "$$(dirname $$(dirname $$(dirname $(execpath %s))))" % marker

def _dirname(label):
    return "$$(dirname $(execpath %s))" % label

def _action_path(path):
    return path if path.startswith("/") else "/proc/self/cwd/" + path

def _bootstrap_env():
    sysroot = _sysroot("@musl_amd64_sysroot//:usr/include/stdio.h")
    resource_dir = sysroot + "/usr/lib/llvm22/lib/clang/22"
    compile_flags = " ".join([
        "--target=x86_64-alpine-linux-musl",
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-B" + sysroot + "/usr/lib/",
        "-O2",
    ])
    link_flags = " ".join([
        compile_flags,
        "--rtlib=compiler-rt",
        "--unwindlib=libunwind",
        "-fuse-ld=" + _llvm_tool("ld.lld"),
        "-static",
        "-no-pie",
    ])
    return {
        "AR": _llvm_tool("ar"),
        "CC": _llvm_tool("clang"),
        "CFLAGS": compile_flags,
        "CONFIG_SHELL": _toolbox_shell(),
        "CXX": _llvm_tool("clang++"),
        "CXXFLAGS": compile_flags,
        "HOME": "$$BUILD_TMPDIR",
        "LD": _llvm_tool("ld.lld"),
        "LDFLAGS": link_flags,
        "NM": _llvm_tool("nm"),
        "OBJCOPY": _llvm_tool("objcopy"),
        "OBJDUMP": _llvm_tool("objdump"),
        "PATH": _foreign_path(),
        "PERL": "$(execpath //fips/toolchains:foreign_perl)",
        "READELF": _llvm_tool("readelf"),
        "SOURCE_DATE_EPOCH": "0",
        "SHELL": _toolbox_shell(),
        "STRIP": _llvm_tool("strip"),
        "TMPDIR": "$$BUILD_TMPDIR",
    }

def _otp_bootstrap_finalize_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    native = _directory_named(ctx.attr.foreign[DefaultInfo].files.to_list(), "native")
    erl = ctx.actions.declare_file(ctx.label.name + "_bin/erl")
    erlc = ctx.actions.declare_file(ctx.label.name + "_bin/erlc")
    escript = ctx.actions.declare_file(ctx.label.name + "_bin/escript")
    go_state = ctx.actions.declare_directory(ctx.label.name + "_bin/go_state")
    otp_build_triplet = "x86_64-alpine-linux-musl"

    ctx.actions.run(
        arguments = [
            "build",
            "-trimpath",
            "-ldflags=-s -w -X main.bindir=bin/%s -X main.rootdir=bootstrap" % otp_build_triplet,
            "-o",
            erl.path,
            ctx.file.bootstrap_entrypoint_source.path,
        ],
        env = {
            "CGO_ENABLED": "0",
            "GOCACHE": "/proc/self/cwd/" + go_state.path + "/cache",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": "amd64",
            "GOPATH": "/proc/self/cwd/" + go_state.path + "/path",
            "GOTOOLCHAIN": "local",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = platform.go_bin,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [ctx.file.bootstrap_entrypoint_source],
            transitive = [platform.go_files],
        ),
        mnemonic = "OtpBootstrapEntrypointCompile",
        outputs = [erl, go_state],
        progress_message = "Compiling shell-free OTP bootstrap entry point",
    )
    ctx.actions.symlink(is_executable = True, output = erlc, target_file = erl)
    ctx.actions.symlink(is_executable = True, output = escript, target_file = erl)
    return [
        DefaultInfo(files = depset([native, erl, erlc, escript])),
        FipsOtpBootstrapInfo(
            bin_dir = erl.dirname,
            bindir = "bin/" + otp_build_triplet,
            erl = erl,
            erlc = erlc,
            escript = escript,
            root = native,
            rootdir = "bootstrap",
            version = ctx.attr.otp_version,
        ),
    ]

_otp_bootstrap_finalize = rule(
    implementation = _otp_bootstrap_finalize_impl,
    attrs = {
        "bootstrap_entrypoint_source": attr.label(
            allow_single_file = [".go"],
            default = "//tools/otp_bootstrap_exec:main.go",
        ),
        "foreign": attr.label(mandatory = True),
        "otp_version": attr.string(default = OTP_SOURCE.version),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def _bootstrap_artifact_impl(ctx):
    bootstrap = ctx.attr.bootstrap[FipsOtpBootstrapInfo]
    artifacts = {
        "erl": bootstrap.erl,
        "erlc": bootstrap.erlc,
        "escript": bootstrap.escript,
        "root": bootstrap.root,
    }
    return [DefaultInfo(files = depset([artifacts[ctx.attr.kind]]))]

_bootstrap_artifact = rule(
    implementation = _bootstrap_artifact_impl,
    attrs = {
        "bootstrap": attr.label(mandatory = True, providers = [FipsOtpBootstrapInfo]),
        "kind": attr.string(mandatory = True, values = ["erl", "erlc", "escript", "root"]),
    },
)

def _crypto_artifact_impl(ctx):
    crypto = ctx.attr.crypto[FipsCryptoInfo]
    if ctx.attr.kind == "include":
        artifact = crypto.include_dir
    elif ctx.attr.kind == "libcrypto":
        artifact = _file_named(crypto.static_libs.to_list(), "libcrypto.a")
    elif ctx.attr.kind == "libssl":
        artifact = _file_named(crypto.static_libs.to_list(), "libssl.a")
    else:
        artifact = _file_named(crypto.runtime_files.to_list(), ctx.attr.kind)
    return [DefaultInfo(files = depset([artifact]))]

_crypto_artifact = rule(
    implementation = _crypto_artifact_impl,
    attrs = {
        "crypto": attr.label(mandatory = True, providers = [FipsCryptoInfo]),
        "kind": attr.string(
            mandatory = True,
            values = ["fips.so", "include", "libcrypto", "libssl", "openssl", "openssl-fips.cnf"],
        ),
    },
)

def _openssl_module_config_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    crypto = ctx.attr.crypto[FipsCryptoInfo]
    runtime_files = crypto.runtime_files.to_list()
    openssl_bin = _file_named(runtime_files, "openssl")
    fips_module = _file_named(runtime_files, "fips.so")
    output = ctx.actions.declare_file(ctx.label.name + "/fipsmodule.cnf")
    arguments = [
        "--library-path",
        platform.musl_libc_file.dirname + ":" + platform.sysroot_path + "/usr/lib",
        openssl_bin.path,
        "fipsinstall",
        "-module",
        fips_module.path,
        "-out",
        output.path,
        "-pedantic",
    ]
    executable = platform.musl_loader_file
    if platform.arch == "arm64":
        arguments = [platform.musl_loader_file.path] + arguments
        executable = platform.qemu_aarch64_file
    ctx.actions.run(
        arguments = arguments,
        env = {
            "OPENSSL_CONF": "/dev/null",
            "OPENSSL_MODULES": fips_module.dirname,
        },
        executable = executable,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [openssl_bin, fips_module],
            transitive = [platform.qemu_aarch64_files, platform.sysroot_files],
        ),
        mnemonic = "OpenSslFipsModuleConfig",
        outputs = [output],
        progress_message = "Generating OpenSSL FIPS module configuration for %s" % platform.arch,
    )
    return [DefaultInfo(files = depset([output]))]

_openssl_module_config = rule(
    implementation = _openssl_module_config_impl,
    attrs = {
        "crypto": attr.label(mandatory = True, providers = [FipsCryptoInfo]),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def otp_native_bootstrap(name, otp_version = OTP_SOURCE.version, visibility = None, tags = None):
    """Builds OTP's native bootstrap with configure_make.

    Args:
      name: Bootstrap target name.
      otp_version: OTP version recorded in the provider.
      visibility: Optional target visibility.
      tags: Optional tags applied to generated targets.
    """
    foreign_name = name + "_foreign"
    common = {}
    if tags != None:
        common["tags"] = tags

    configure_make(
        name = foreign_name,
        args = [
            "-s",
            "-j8",
            "RANLIB=$$EXT_BUILD_ROOT$$/" + _llvm_tool("ranlib"),
        ],
        build_data = _llvm_build_data() + [
            "@musl_amd64_sysroot//:sysroot",
            "@musl_amd64_sysroot//:usr/include/stdio.h",
            "//fips/private:fips_artifact_validator",
        ],
        configure_in_place = True,
        configure_options = [
            "--build=x86_64-alpine-linux-musl",
            "--host=x86_64-alpine-linux-musl",
            "--enable-bootstrap-only",
            "--enable-builtin-zlib",
            "--disable-jit",
            "--disable-pie",
            "--without-termcap",
            "--without-javac",
            "--without-wx",
            "--without-ssl",
        ],
        env = _bootstrap_env(),
        install_prefix = "stage",
        lib_source = "@otp_src//:srcs",
        out_data_dirs = ["native"],
        out_headers_only = True,
        out_include_dir = "",
        postfix_script = "$(execpath //fips/private:fips_artifact_validator) stage-otp-bootstrap $$BUILD_TMPDIR $$INSTALLDIR",
        targets = [""],
        **common
    )

    final_args = dict(common)
    final_args.update({
        "foreign": ":" + foreign_name,
        "otp_version": otp_version,
    })
    if visibility != None:
        final_args["visibility"] = visibility
    _otp_bootstrap_finalize(
        name = name,
        **final_args
    )

def _target_env(marker, triplet, loader, aliases):
    sysroot = _sysroot(marker)
    resource_dir = sysroot + "/usr/lib/llvm22/lib/clang/22"
    compile_flags = " ".join([
        "--target=" + triplet,
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-B" + sysroot + "/usr/lib/",
        "-O2",
    ])
    base_link_flags = " ".join([
        compile_flags,
        "--rtlib=compiler-rt",
        "--unwindlib=libunwind",
        "-fuse-ld=" + _llvm_tool("ld.lld"),
        "-Wl,-S",
        "-Wl,-z,relro,-z,now",
    ])
    link_flags = base_link_flags + " -Wl,--dynamic-linker=/opt/fips-elixir/lib/%s -Wl,-rpath,/opt/fips-elixir/lib" % loader
    libs = " ".join([
        "-Wl,--start-group",
        "$(execpath %s)" % aliases.libssl,
        "$(execpath %s)" % aliases.libcrypto,
        "-Wl,--end-group",
        "-ldl",
        "-pthread",
        "-lm",
    ])

    env = {
        "AR": _llvm_tool("ar"),
        "BOOTSTRAP_BIN": _dirname(aliases.erl),
        "CC": _llvm_tool("clang"),
        "CFLAGS": compile_flags,
        "CONFIG_SHELL": _toolbox_shell(),
        "CXX": _llvm_tool("clang++"),
        "CXXFLAGS": compile_flags + " -stdlib=libc++",
        "HOME": "$$BUILD_TMPDIR",
        "LD": _llvm_tool("ld.lld"),
        "LDFLAGS": link_flags,
        "LIBS": libs,
        "NM": _llvm_tool("nm"),
        "OBJCOPY": _llvm_tool("objcopy"),
        "OBJDUMP": _llvm_tool("objdump"),
        "OTP_BOOTSTRAP_ROOT": "$(execpath %s)" % aliases.root,
        "PATH": _foreign_path(_dirname(aliases.erl)),
        "PERL": "$(execpath //fips/toolchains:foreign_perl)",
        "READELF": _llvm_tool("readelf"),
        "SOURCE_DATE_EPOCH": "0",
        "SHELL": _toolbox_shell(),
        "STATIC_CFLAGS": compile_flags,
        "STRIP": _llvm_tool("strip"),
        "STATIC_LDFLAGS": base_link_flags + " -static -no-pie",
        "TMPDIR": "$$BUILD_TMPDIR",
        "erl_xcomp_bigendian": "no",
        "erl_xcomp_double_middle_endian": "no",
        "erl_xcomp_isysroot": sysroot,
        "erl_xcomp_sysroot": sysroot,
    }
    env.update({
        "FIPS_MODULE_CONF": "$(execpath %s)" % aliases.module_config,
        "OPENSSL_CONF": "$(execpath %s)" % aliases.openssl_config,
        "OPENSSL_MODULES": _dirname(aliases.fips_module),
    })
    return env

def _target_options(triplet, aliases):
    options = [
        "--build=x86_64-alpine-linux-musl",
        "--host=" + triplet,
        "--prefix=/opt/fips-elixir",
        "--with-ssl=" + _dirname(aliases.libssl),
        "--with-ssl-lib-subdir=.",
        "--with-ssl-incl=" + _dirname(aliases.include),
        "--disable-dynamic-ssl-lib",
        "--with-ssl-rpath=no",
        "--enable-fips",
        "--enable-static-nifs=yes",
        "--enable-static-drivers=yes",
        "--enable-builtin-zlib",
        "--enable-builtin-zstd",
        "--disable-jit",
        "--disable-pie",
        "--disable-systemd",
        "--without-termcap",
        "--without-javac",
        "--without-wx",
        "--without-debugger",
        "--without-observer",
        "--without-et",
        "--without-odbc",
        "--without-runtime_tools",
    ]
    return options

def _otp_target_finalize_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    crypto = ctx.attr.crypto[FipsCryptoInfo]
    if crypto.backend != "openssl":
        fail("OTP FIPS runtime requires the OpenSSL backend")
    foreign_files = ctx.attr.foreign[DefaultInfo].files.to_list()
    root = _directory_named(foreign_files, "runtime")
    tools_ebin = _directory_named(foreign_files, "tools_ebin")
    runtime_files = crypto.runtime_files.to_list()
    openssl_config = _file_named(runtime_files, "openssl-fips.cnf", required = False)
    fips_module = _file_named(runtime_files, "fips.so", required = False)
    stamp = ctx.actions.declare_file(ctx.label.name + "/OTP_FIPS_VERIFIED")
    module_config = ctx.file.module_config

    ctx.actions.run(
        arguments = [
            "otp",
            _action_path(root.path),
            crypto.backend,
            _action_path(platform.musl_loader_path),
            _action_path(platform.musl_libc_file.dirname),
            _action_path(platform.sysroot_path),
            _action_path(platform.qemu_aarch64_file.path) if platform.arch == "arm64" else "-",
            _action_path(openssl_config.path) if openssl_config else "-",
            _action_path(fips_module.path) if fips_module else "-",
            _action_path(module_config.path) if module_config else "-",
            _action_path(stamp.path),
            crypto.module_version,
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
                root,
                tools_ebin,
            ] + runtime_files + ([module_config] if module_config else []),
            transitive = [platform.qemu_aarch64_files, platform.sysroot_files],
        ),
        mnemonic = "OtpFipsRuntimeValidate",
        outputs = [stamp],
        progress_message = "Validating OTP FIPS runtime for %s" % platform.arch,
    )
    return [
        DefaultInfo(files = depset([root, tools_ebin, stamp])),
        FipsOtpRuntimeInfo(
            backend = crypto.backend,
            root = root,
            tools_ebin = tools_ebin,
            version = ctx.attr.otp_version,
        ),
    ]

_otp_target_finalize = rule(
    implementation = _otp_target_finalize_impl,
    attrs = {
        "crypto": attr.label(mandatory = True, providers = [FipsCryptoInfo]),
        "foreign": attr.label(mandatory = True),
        "module_config": attr.label(allow_single_file = True),
        "otp_version": attr.string(default = OTP_SOURCE.version),
        "validator": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = "//fips/private:fips_artifact_validator",
            executable = True,
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def otp_fips_runtime(
        name,
        bootstrap,
        crypto,
        otp_version = OTP_SOURCE.version,
        visibility = None,
        tags = None):
    """Builds target OTP with configure_make and validates FIPS at runtime.

    Args:
      name: Target OTP name.
      bootstrap: Label providing the native OTP bootstrap.
      crypto: Label providing the OpenSSL build.
      otp_version: OTP version recorded in evidence.
      visibility: Optional target visibility.
      tags: Optional tags applied to generated targets.
    """
    common = {}
    if tags != None:
        common["tags"] = tags
    aliases = struct(
        erl = ":" + name + "_bootstrap_erl",
        erlc = ":" + name + "_bootstrap_erlc",
        escript = ":" + name + "_bootstrap_escript",
        include = ":" + name + "_crypto_include",
        libcrypto = ":" + name + "_crypto_libcrypto",
        libssl = ":" + name + "_crypto_libssl",
        root = ":" + name + "_bootstrap_root",
        fips_module = ":" + name + "_crypto_fips_module",
        module_config = ":" + name + "_module_config",
        openssl_config = ":" + name + "_crypto_openssl_config",
    )
    _bootstrap_artifact(name = name + "_bootstrap_erl", bootstrap = bootstrap, kind = "erl", **common)
    _bootstrap_artifact(name = name + "_bootstrap_erlc", bootstrap = bootstrap, kind = "erlc", **common)
    _bootstrap_artifact(name = name + "_bootstrap_escript", bootstrap = bootstrap, kind = "escript", **common)
    _bootstrap_artifact(name = name + "_bootstrap_root", bootstrap = bootstrap, kind = "root", **common)
    _crypto_artifact(name = name + "_crypto_include", crypto = crypto, kind = "include", **common)
    _crypto_artifact(name = name + "_crypto_libcrypto", crypto = crypto, kind = "libcrypto", **common)
    _crypto_artifact(name = name + "_crypto_libssl", crypto = crypto, kind = "libssl", **common)

    data = [
        aliases.erl,
        aliases.erlc,
        aliases.escript,
        aliases.include,
        aliases.libcrypto,
        aliases.libssl,
        aliases.root,
    ]
    build_data = _llvm_build_data() + [
        "//fips/private:fips_artifact_validator",
    ]
    _crypto_artifact(name = name + "_crypto_fips_module", crypto = crypto, kind = "fips.so", **common)
    _crypto_artifact(name = name + "_crypto_openssl_config", crypto = crypto, kind = "openssl-fips.cnf", **common)
    _openssl_module_config(name = name + "_module_config", crypto = crypto, **common)
    data.extend([aliases.fips_module, aliases.module_config, aliases.openssl_config])
    data += select({
        _TARGET_AMD64: ["@musl_amd64_sysroot//:sysroot", "@musl_amd64_sysroot//:usr/include/stdio.h"],
        _TARGET_ARM64: ["@musl_arm64_sysroot//:sysroot", "@musl_arm64_sysroot//:usr/include/stdio.h"],
    })

    foreign_name = name + "_foreign"
    configure_make(
        name = foreign_name,
        args = select({
            _TARGET_AMD64: [
                "-s",
                "-j8",
                "BOOT_PREFIX=$$BOOTSTRAP_BIN$$:",
                "INSTALL_PREFIX=",
                "OVERRIDE_TARGET=x86_64-pc-linux-musl",
                "RANLIB=$$EXT_BUILD_ROOT$$/" + _llvm_tool("ranlib"),
                "CS_LDFLAGS=\"$$STATIC_LDFLAGS$$\"",
            ],
            _TARGET_ARM64: [
                "-s",
                "-j8",
                "BOOT_PREFIX=$$BOOTSTRAP_BIN$$:",
                "INSTALL_PREFIX=",
                "OVERRIDE_TARGET=aarch64-alpine-linux-musl",
                "RANLIB=$$EXT_BUILD_ROOT$$/" + _llvm_tool("ranlib"),
                "CS_LDFLAGS=\"$$STATIC_LDFLAGS$$\"",
            ],
        }),
        build_data = build_data,
        configure_in_place = True,
        configure_options = select({
            _TARGET_AMD64: _target_options(
                "x86_64-linux-musl",
                aliases,
            ),
            _TARGET_ARM64: _target_options(
                "aarch64-alpine-linux-musl",
                aliases,
            ),
        }),
        data = data,
        env = select({
            _TARGET_AMD64: _target_env(
                "@musl_amd64_sysroot//:usr/include/stdio.h",
                "x86_64-alpine-linux-musl",
                "ld-musl-x86_64.so.1",
                aliases,
            ),
            _TARGET_ARM64: _target_env(
                "@musl_arm64_sysroot//:usr/include/stdio.h",
                "aarch64-alpine-linux-musl",
                "ld-musl-aarch64.so.1",
                aliases,
            ),
        }),
        install_prefix = "stage",
        lib_source = "@otp_src//:srcs",
        out_data_dirs = ["runtime", "tools_ebin"],
        out_headers_only = True,
        out_include_dir = "",
        postfix_script = "$(execpath //fips/private:fips_artifact_validator) stage-otp-tools $$BUILD_TMPDIR $$INSTALLDIR",
        targets = [
            "-C lib ERL_TOP=$$BUILD_TMPDIR$$ BUILD_STATIC_LIBS=1 TYPE=opt static_lib",
            "",
            "-C lib/erl_interface/src ERL_TOP=$$BUILD_TMPDIR$$ clean",
            "-C lib/erl_interface/src ERL_TOP=$$BUILD_TMPDIR$$ LDFLAGS=\"$$STATIC_LDFLAGS$$\" opt",
            "-C erts/etc/common ERL_TOP=$$BUILD_TMPDIR$$ clean",
            "-C erts/etc/common ERL_TOP=$$BUILD_TMPDIR$$ LDFLAGS=\"$$STATIC_LDFLAGS$$\"",
            "-C erts/epmd/src ERL_TOP=$$BUILD_TMPDIR$$ clean",
            "-C erts/epmd/src ERL_TOP=$$BUILD_TMPDIR$$ LDFLAGS=\"$$STATIC_LDFLAGS$$\"",
            "-C lib/os_mon/c_src ERL_TOP=$$BUILD_TMPDIR$$ clean",
            "-C lib/os_mon/c_src ERL_TOP=$$BUILD_TMPDIR$$ LDFLAGS=\"$$STATIC_LDFLAGS$$\" opt",
            "install DESTDIR=$$BUILD_TMPDIR$$/stage/runtime",
        ],
        **common
    )

    final_args = dict(common)
    final_args.update({
        "crypto": crypto,
        "foreign": ":" + foreign_name,
        "otp_version": otp_version,
    })
    final_args["module_config"] = aliases.module_config
    if visibility != None:
        final_args["visibility"] = visibility
    _otp_target_finalize(name = name, **final_args)
