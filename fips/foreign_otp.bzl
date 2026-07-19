"""rules_foreign_cc-backed OTP bootstrap and target builds."""

load("@rules_foreign_cc//foreign_cc:defs.bzl", "configure_make")
load(
    "//fips:providers.bzl",
    "FipsCryptoInfo",
    "FipsOtpBootstrapInfo",
    "FipsOtpRuntimeInfo",
)

_TOOLCHAIN_TYPE = "//fips:toolchain_type"
_TARGET_AMD64 = "//fips/platforms:target_amd64"
_TARGET_ARM64 = "//fips/platforms:target_arm64"

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

def _parent(label):
    return "$$(dirname $$(dirname $(execpath %s)))" % label

def _action_path(path):
    return path if path.startswith("/") else "/proc/self/cwd/" + path

def _bootstrap_env():
    clang_root = "$(execpath @fips_clang_amd64//sysroot:sysroot)"
    sysroot = _sysroot("@linux_amd64_sysroot//:usr/include/stdio.h")
    resource_dir = clang_root + "/lib/clang/22"
    compiler_rt = _sysroot("@musl_amd64_sysroot//:usr/include/stdio.h") + "/usr/lib/llvm22/lib/clang/22/lib/x86_64-alpine-linux-musl/libclang_rt.builtins-x86_64.a"
    compile_flags = " ".join([
        "--target=x86_64-linux-gnu",
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-O2",
    ])
    return {
        "AR": clang_root + "/bin/llvm-ar",
        "CC": clang_root + "/bin/clang",
        "CFLAGS": compile_flags,
        "CXX": clang_root + "/bin/clang++",
        "CXXFLAGS": compile_flags,
        "HOME": "$$BUILD_TMPDIR",
        "LD": clang_root + "/bin/ld.lld",
        "LDFLAGS": compile_flags + " -fuse-ld=lld -no-pie",
        "LD_LIBRARY_PATH": "$(execpath //fips/toolchains:llvm_libxml2_amd64)/usr/lib/x86_64-linux-gnu:$(execpath //fips/toolchains:llvm_libicu_amd64)/usr/lib/x86_64-linux-gnu",
        "LIBS": compiler_rt,
        "NM": clang_root + "/bin/llvm-nm",
        "OBJCOPY": clang_root + "/bin/llvm-objcopy",
        "OBJDUMP": clang_root + "/bin/llvm-objdump",
        "READELF": clang_root + "/bin/llvm-readelf",
        "SOURCE_DATE_EPOCH": "0",
        "STRIP": clang_root + "/bin/llvm-strip",
        "TMPDIR": "$$BUILD_TMPDIR",
    }

def _otp_bootstrap_finalize_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    native = _directory_named(ctx.attr.foreign[DefaultInfo].files.to_list(), "native")
    erl = ctx.actions.declare_file(ctx.label.name + "_bin/erl")
    erlc = ctx.actions.declare_file(ctx.label.name + "_bin/erlc")
    escript = ctx.actions.declare_file(ctx.label.name + "_bin/escript")
    go_state = ctx.actions.declare_directory(ctx.label.name + "_bin/go_state")
    otp_build_triplet = "x86_64-pc-linux-gnu"

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
        "otp_version": attr.string(default = "29.0.3"),
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
    ctx.actions.run(
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
        ],
        env = {
            "OPENSSL_CONF": "/dev/null",
            "OPENSSL_MODULES": fips_module.dirname,
        },
        executable = platform.musl_loader_file,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [openssl_bin, fips_module],
            transitive = [platform.sysroot_files],
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

def otp_native_bootstrap(name, otp_version = "29.0.3", visibility = None, tags = None):
    """Builds OTP's native bootstrap with configure_make."""
    foreign_name = name + "_foreign"
    common = {}
    if tags != None:
        common["tags"] = tags

    configure_make(
        name = foreign_name,
        args = [
            "-s",
            "-j8",
            "RANLIB=$$EXT_BUILD_ROOT$$/$(execpath @fips_clang_amd64//sysroot:sysroot)/bin/llvm-ranlib",
        ],
        build_data = [
            "@fips_clang_amd64//sysroot:sysroot",
            "@linux_amd64_sysroot//:sysroot",
            "@linux_amd64_sysroot//:usr/include/stdio.h",
            "@musl_amd64_sysroot//:sysroot",
            "@musl_amd64_sysroot//:usr/include/stdio.h",
            "//fips/private:fips_artifact_validator",
            "//fips/toolchains:llvm_libicu_amd64",
            "//fips/toolchains:llvm_libxml2_amd64",
        ],
        configure_in_place = True,
        configure_options = [
            "--build=x86_64-linux-gnu",
            "--host=x86_64-linux-gnu",
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

def _target_env(marker, triplet, loader, backend, aliases):
    clang_root = "$(execpath @fips_clang_amd64//sysroot:sysroot)"
    sysroot = _sysroot(marker)
    resource_dir = sysroot + "/usr/lib/llvm22/lib/clang/22"
    compile_flags = " ".join([
        "--target=" + triplet,
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-B" + sysroot + "/usr/lib/",
        "-O2",
    ])
    link_flags = " ".join([
        compile_flags,
        "--rtlib=compiler-rt",
        "--unwindlib=libunwind",
        "-fuse-ld=lld",
        "-Wl,-S",
        "-Wl,-z,relro,-z,now",
    ])
    if backend == "boringssl":
        link_flags += " -static -no-pie"
        libs = " ".join([
            "-Wl,--start-group",
            "$(execpath %s)" % aliases.libssl,
            "$(execpath %s)" % aliases.libcrypto,
            "-lc++",
            "-lc++abi",
            "-lunwind",
            "-Wl,--end-group",
            "-ldl",
            "-pthread",
            "-lm",
        ])
    else:
        link_flags += " -Wl,--dynamic-linker=/opt/fips-elixir/lib/%s -Wl,-rpath,/opt/fips-elixir/lib" % loader
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
        "AR": clang_root + "/bin/llvm-ar",
        "BOOTSTRAP_BIN": _dirname(aliases.erl),
        "CC": clang_root + "/bin/clang",
        "CFLAGS": compile_flags,
        "CXX": clang_root + "/bin/clang++",
        "CXXFLAGS": compile_flags + " -stdlib=libc++",
        "HOME": "$$BUILD_TMPDIR",
        "LD": clang_root + "/bin/ld.lld",
        "LDFLAGS": link_flags,
        "LD_LIBRARY_PATH": "$(execpath //fips/toolchains:llvm_libxml2_amd64)/usr/lib/x86_64-linux-gnu:$(execpath //fips/toolchains:llvm_libicu_amd64)/usr/lib/x86_64-linux-gnu",
        "LIBS": libs,
        "NM": clang_root + "/bin/llvm-nm",
        "OBJCOPY": clang_root + "/bin/llvm-objcopy",
        "OBJDUMP": clang_root + "/bin/llvm-objdump",
        "OTP_BOOTSTRAP_ROOT": "$(execpath %s)" % aliases.root,
        "PATH": _dirname(aliases.erl) + ":/bin:/usr/bin",
        "READELF": clang_root + "/bin/llvm-readelf",
        "SOURCE_DATE_EPOCH": "0",
        "STATIC_CFLAGS": compile_flags,
        "STRIP": clang_root + "/bin/llvm-strip",
        "TMPDIR": "$$BUILD_TMPDIR",
        "erl_xcomp_bigendian": "no",
        "erl_xcomp_double_middle_endian": "no",
        "erl_xcomp_isysroot": sysroot,
        "erl_xcomp_sysroot": sysroot,
    }
    if backend == "boringssl":
        compat_include = "-I" + _parent("//compat/boringssl:openssl/modes.h")
        env["CFLAGS"] = compat_include + " " + compile_flags
        env["CPPFLAGS"] = compat_include
        env["STATIC_CFLAGS"] = compat_include + " " + compile_flags
    else:
        env.update({
            "FIPS_MODULE_CONF": "$(execpath %s)" % aliases.module_config,
            "OPENSSL_CONF": "$(execpath %s)" % aliases.openssl_config,
            "OPENSSL_MODULES": _dirname(aliases.fips_module),
        })
    return env

def _target_options(marker, triplet, aliases, backend):
    options = [
        "--build=x86_64-linux-gnu",
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
    if backend == "boringssl":
        options.extend(["--disable-evp-dh", "--disable-evp-hmac"])
    return options

def _otp_target_finalize_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    crypto = ctx.attr.crypto[FipsCryptoInfo]
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
            _action_path(openssl_config.path) if openssl_config else "-",
            _action_path(fips_module.path) if fips_module else "-",
            _action_path(module_config.path) if module_config else "-",
            _action_path(stamp.path),
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
            transitive = [platform.sysroot_files],
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
        "otp_version": attr.string(default = "29.0.3"),
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
        backend = "openssl",
        otp_version = "29.0.3",
        visibility = None,
        tags = None):
    """Builds target OTP with configure_make and validates FIPS at runtime."""
    if backend not in ["openssl", "boringssl"]:
        fail("unsupported OTP FIPS backend: %s" % backend)

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
    build_data = [
        "@fips_clang_amd64//sysroot:sysroot",
        "//fips/private:fips_artifact_validator",
        "//fips/toolchains:llvm_libicu_amd64",
        "//fips/toolchains:llvm_libxml2_amd64",
    ]
    if backend == "boringssl":
        data.extend([
            "//compat/boringssl:headers",
            "//compat/boringssl:openssl/modes.h",
        ])
    else:
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
                "OVERRIDE_TARGET=x86_64-alpine-linux-musl",
                "RANLIB=$$EXT_BUILD_ROOT$$/$(execpath @fips_clang_amd64//sysroot:sysroot)/bin/llvm-ranlib",
            ],
            _TARGET_ARM64: [
                "-s",
                "-j8",
                "BOOT_PREFIX=$$BOOTSTRAP_BIN$$:",
                "INSTALL_PREFIX=",
                "OVERRIDE_TARGET=aarch64-alpine-linux-musl",
                "RANLIB=$$EXT_BUILD_ROOT$$/$(execpath @fips_clang_amd64//sysroot:sysroot)/bin/llvm-ranlib",
            ],
        }),
        build_data = build_data,
        configure_in_place = True,
        configure_options = select({
            _TARGET_AMD64: _target_options(
                "@musl_amd64_sysroot//:usr/include/stdio.h",
                "x86_64-alpine-linux-musl",
                aliases,
                backend,
            ),
            _TARGET_ARM64: _target_options(
                "@musl_arm64_sysroot//:usr/include/stdio.h",
                "aarch64-alpine-linux-musl",
                aliases,
                backend,
            ),
        }),
        data = data,
        env = select({
            _TARGET_AMD64: _target_env(
                "@musl_amd64_sysroot//:usr/include/stdio.h",
                "x86_64-alpine-linux-musl",
                "ld-musl-x86_64.so.1",
                backend,
                aliases,
            ),
            _TARGET_ARM64: _target_env(
                "@musl_arm64_sysroot//:usr/include/stdio.h",
                "aarch64-alpine-linux-musl",
                "ld-musl-aarch64.so.1",
                backend,
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
    if backend == "openssl":
        final_args["module_config"] = aliases.module_config
    if visibility != None:
        final_args["visibility"] = visibility
    _otp_target_finalize(name = name, **final_args)
