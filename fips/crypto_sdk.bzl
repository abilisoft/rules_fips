"""Normalized crypto SDK exports for backend-neutral language rules."""

load(
    "//fips:providers.bzl",
    "FipsCryptoInfo",
    "FipsCryptoSdkInfo",
    "HermeticRuntimeEnvironmentInfo",
)
load(
    "//fips/toolchains:runtime_tool.bzl",
    "hermetic_target_runtime_test",
    "hermetic_target_runtime_tool",
)

_TOOLCHAIN_TYPE = Label("//fips:toolchain_type")
_ACTIVATION_SOURCE = Label("//tools/crypto_activation:main.go")
_RUNTIME_LAUNCHER_SOURCE = Label("//tools/runtime_launcher:main.go")
_STAGER = Label("//fips/private:fips_artifact_validator")
_QEMU_EXEC_SUPPORT = Label("//fips/toolchains:qemu_aarch64_exec_support")
_GO_EXEC = Label("//fips/toolchains:go_exec")
_GLIBC_2_35 = Label("//fips/platforms:glibc_2_35")
_CPU_ARM64 = Label("@platforms//cpu:arm64")
_TARGET_GLIBC_RUNTIME = Label("//fips/toolchains:target_glibc_runtime")
_TARGET_MUSL_RUNTIME = Label("//fips/toolchains:target_musl_runtime")
_RUNTIME_LAYOUT = [
    ("activation", "bin/crypto-activate"),
    ("runtime_launcher", "bin/runtime-launch"),
    ("openssl", "bin/openssl"),
    ("provider", "lib/ossl-modules/fips.so"),
    ("config", "ssl/openssl.cnf"),
    ("libc_runtime", "lib"),
    ("manifest", "evidence/FIPS_BUILD.json"),
    ("openssl_core_license", "licenses/openssl-core-LICENSE.txt"),
    ("openssl_provider_license", "licenses/openssl-fips-provider-LICENSE.txt"),
    ("libc_license", "licenses/libc-LICENSE.txt"),
]

def _file_named(files, basename):
    for file in files:
        if file.basename == basename:
            return file
    fail("crypto SDK input did not contain {}".format(basename))

def _static_library(crypto, basename):
    return _file_named(crypto.static_libs.to_list(), basename)

def _static_go_tool_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    executable = ctx.actions.declare_file(ctx.label.name)
    go_state = ctx.actions.declare_directory(ctx.label.name + "_go_state")
    goarch = "amd64" if platform.arch == "amd64" else "arm64"
    ctx.actions.run(
        arguments = [
            "build",
            "-trimpath",
            "-ldflags=-s -w",
            "-o",
            executable.path,
            ctx.file.source.path,
        ],
        env = {
            "CGO_ENABLED": "0",
            "GOCACHE": "/proc/self/cwd/" + go_state.path + "/cache",
            # Go changes its compiler subprocess working directories. Scratch
            # must use an absolute executor path and is never an action input.
            "GOTMPDIR": "/tmp",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": goarch,
            "GOPATH": "/proc/self/cwd/" + go_state.path + "/path",
            "GOTOOLCHAIN": "local",
            "LANG": "C",
            "LC_ALL": "C",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = platform.go_bin,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [ctx.file.source],
            transitive = [platform.go_files],
        ),
        mnemonic = "CryptoActivationCompile",
        outputs = [executable, go_state],
        progress_message = "Compiling {} for {}".format(ctx.attr.description, platform.arch),
    )
    return [DefaultInfo(
        executable = executable,
        files = depset([executable]),
    )]

_static_go_tool = rule(
    implementation = _static_go_tool_impl,
    attrs = {
        "description": attr.string(mandatory = True),
        "source": attr.label(
            allow_single_file = [".go"],
            mandatory = True,
        ),
    },
    executable = True,
    toolchains = [_TOOLCHAIN_TYPE],
)

def _execution_static_go_tool_impl(ctx):
    go_roots = ctx.attr.go[DefaultInfo].files.to_list()
    if len(go_roots) != 1:
        fail("execution Go toolchain must expose exactly one source directory")
    qemu_files = ctx.attr.qemu_aarch64[DefaultInfo].files.to_list()
    if len(qemu_files) > 1:
        fail("execution QEMU support must expose at most one executable")
    qemu = qemu_files[0].path if qemu_files else ""
    executable = ctx.actions.declare_file(ctx.label.name)
    go_cache = ctx.actions.declare_directory(ctx.label.name + "_go_cache")
    go_path = ctx.actions.declare_directory(ctx.label.name + "_go_path")
    ctx.actions.run(
        arguments = [
            "build",
            "-trimpath",
            "-ldflags=-s -w -X main.qemuAarch64={}".format(qemu),
            "-o",
            executable.path,
            ctx.file.source.path,
        ],
        env = {
            "CGO_ENABLED": "0",
            "GOCACHE": "/proc/self/cwd/" + go_cache.path,
            "GOTMPDIR": "/tmp",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": ctx.attr.arch,
            "GOPATH": "/proc/self/cwd/" + go_path.path,
            "GOTOOLCHAIN": "local",
            "LANG": "C",
            "LC_ALL": "C",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = go_roots[0].path + "/bin/go",
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [ctx.file.source],
            transitive = [ctx.attr.go[DefaultInfo].files, ctx.attr.qemu_aarch64[DefaultInfo].files],
        ),
        mnemonic = "ExecutionCryptoToolCompile",
        outputs = [executable, go_cache, go_path],
        progress_message = "Compiling {} for the execution platform".format(ctx.attr.description),
    )
    runtime_files = depset([executable], transitive = [ctx.attr.qemu_aarch64[DefaultInfo].files])
    return [DefaultInfo(
        executable = executable,
        files = runtime_files,
        runfiles = ctx.runfiles(transitive_files = runtime_files),
    )]

_execution_static_go_tool = rule(
    implementation = _execution_static_go_tool_impl,
    attrs = {
        "arch": attr.string(mandatory = True, values = ["amd64", "arm64"]),
        "description": attr.string(mandatory = True),
        "go": attr.label(default = _GO_EXEC),
        "qemu_aarch64": attr.label(
            allow_files = True,
            default = _QEMU_EXEC_SUPPORT,
        ),
        "source": attr.label(
            allow_single_file = [".go"],
            mandatory = True,
        ),
    },
    executable = True,
)

def _crypto_sdk_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    crypto = ctx.attr.crypto[FipsCryptoInfo]
    if crypto.backend != "openssl":
        fail("the current normalized SDK implementation supports OpenSSL inputs only")

    runtime = crypto.runtime_files.to_list()
    artifacts = {
        "activation": ctx.executable.activation,
        "config": _file_named(runtime, "openssl-fips.cnf"),
        "libc_license": platform.libc_license_file,
        "manifest": crypto.manifest,
        "openssl": _file_named(runtime, "openssl"),
        "openssl_core_license": _file_named(runtime, "openssl-core-LICENSE.txt"),
        "openssl_provider_license": _file_named(runtime, "openssl-fips-provider-LICENSE.txt"),
        "provider": _file_named(runtime, "fips.so"),
        "runtime_launcher": ctx.executable.runtime_launcher,
    }
    libcrypto = _static_library(crypto, "libcrypto.a")
    libssl = _static_library(crypto, "libssl.a")
    sysroot = ctx.actions.declare_directory(ctx.label.name + "_sysroot")
    libc_runtime = ctx.actions.declare_directory(ctx.label.name + "_libc_runtime")
    artifacts["libc_runtime"] = libc_runtime
    runtime_arguments = [
        value
        for entry in platform.libc_runtime_entries
        for value in [entry.file.path, entry.destination]
    ]
    header_arguments = ctx.actions.args()
    header_arguments.add_all(
        "--declared-headers",
        [crypto.include_dir],
        expand_directories = True,
        omit_if_empty = False,
    )
    pkg_config_arguments = ctx.actions.args()
    pkg_config_arguments.add_all(
        "--declared-pkg-config",
        [crypto.pkg_config_dir],
        expand_directories = True,
        omit_if_empty = False,
    )
    ctx.actions.run(
        arguments = [
            "stage-crypto-sdk",
            crypto.include_dir.path,
            crypto.pkg_config_dir.path,
            libcrypto.path,
            libssl.path,
            artifacts["openssl"].path,
            artifacts["provider"].path,
            artifacts["config"].path,
            artifacts["activation"].path,
            sysroot.path,
            libc_runtime.path,
        ] + runtime_arguments + [pkg_config_arguments, header_arguments],
        env = {
            "LANG": "C",
            "LC_ALL": "C",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.executable.stager,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [
                crypto.include_dir,
                crypto.pkg_config_dir,
                libcrypto,
                libssl,
                artifacts["activation"],
                artifacts["config"],
                crypto.manifest,
                artifacts["openssl"],
                artifacts["provider"],
            ],
            transitive = [platform.libc_runtime_files],
        ),
        mnemonic = "CryptoSdkStage",
        outputs = [sysroot, libc_runtime],
        progress_message = "Staging normalized crypto SDK for {}".format(platform.arch),
    )

    runtime_files = [artifacts[key] for key, _ in _RUNTIME_LAYOUT]
    runtime_destinations = [destination for _, destination in _RUNTIME_LAYOUT]
    wrapper_environment = {
        "RULES_FIPS_RUNTIME_LIBRARY_PATH": "{sysroot}/lib",
        "RULES_FIPS_RUNTIME_LOADER": "{sysroot}/lib/ld-runtime.so.1",
        "RULES_FIPS_RUNTIME_PROGRAM": "{program}",
    }
    if platform.libc == "glibc":
        wrapper_environment["RULES_FIPS_RUNTIME_INHIBIT_CACHE"] = "true"
    return [
        DefaultInfo(files = depset([sysroot])),
        FipsCryptoSdkInfo(
            activation_args = [
                "--sdk-root",
                "{sysroot}",
                "fipsinstall",
                "-module",
                "{sysroot}/lib/ossl-modules/fips.so",
                "-out",
                "{activation_root}/fipsmodule.cnf",
                "-pedantic",
            ],
            activation_exec_tool = ctx.attr.activation_exec[DefaultInfo].files_to_run,
            activation_tool = ctx.attr.activation[DefaultInfo].files_to_run,
            activation_tool_release_path = "bin/crypto-activate",
            artifacts = artifacts,
            backend_metadata = {
                "backend": crypto.backend,
                "certificate_reference": crypto.certificate,
                "module_name": crypto.module_name,
                "module_version": crypto.module_version,
            },
            crypto = crypto,
            execution_wrapper = ctx.attr.runtime_launcher[DefaultInfo].files_to_run,
            execution_wrapper_environment = wrapper_environment,
            execution_wrapper_release_path = "bin/runtime-launch",
            fully_static = False,
            linkopts = ["-ldl", "-pthread", "-lm"],
            runtime_destinations = runtime_destinations,
            runtime_environment = {
                "FIPS_MODULE_CONF": "{activation_root}/fipsmodule.cnf",
                "OPENSSL_CONF": "{sysroot}/ssl/openssl.cnf",
                "OPENSSL_MODULES": "{sysroot}/lib/ossl-modules",
            },
            runtime_files = runtime_files,
            sysroot = sysroot,
        ),
    ]

_crypto_sdk = rule(
    implementation = _crypto_sdk_impl,
    attrs = {
        "activation": attr.label(
            cfg = "target",
            executable = True,
            mandatory = True,
        ),
        "activation_exec": attr.label(
            cfg = "exec",
            executable = True,
            mandatory = True,
        ),
        "crypto": attr.label(
            mandatory = True,
            providers = [FipsCryptoInfo],
        ),
        "runtime_launcher": attr.label(
            cfg = "target",
            executable = True,
            mandatory = True,
        ),
        "stager": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = _STAGER,
            executable = True,
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def _crypto_sdk_artifact_impl(ctx):
    sdk = ctx.attr.sdk[FipsCryptoSdkInfo]
    return [DefaultInfo(files = depset([sdk.artifacts[ctx.attr.kind]]))]

_crypto_sdk_artifact = rule(
    implementation = _crypto_sdk_artifact_impl,
    attrs = {
        "kind": attr.string(
            mandatory = True,
            values = [key for key, _ in _RUNTIME_LAYOUT],
        ),
        "sdk": attr.label(
            mandatory = True,
            providers = [FipsCryptoSdkInfo],
        ),
    },
)

def _crypto_sdk_executable_artifact_impl(ctx):
    sdk = ctx.attr.sdk[FipsCryptoSdkInfo]
    program = sdk.artifacts[ctx.attr.kind]
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = program,
        is_executable = True,
    )
    return [DefaultInfo(
        executable = executable,
        files = depset([executable, program]),
        runfiles = ctx.runfiles(files = [executable, program]),
    )]

_crypto_sdk_executable_artifact = rule(
    implementation = _crypto_sdk_executable_artifact_impl,
    attrs = {
        "kind": attr.string(mandatory = True, values = ["openssl"]),
        "sdk": attr.label(
            mandatory = True,
            providers = [FipsCryptoSdkInfo],
        ),
    },
    executable = True,
)

def _expand_sdk_path(value, sysroot, activation_root):
    return value.replace("{sysroot}", sysroot).replace("{activation_root}", activation_root)

def _crypto_sdk_runtime_environment_impl(ctx):
    sdk = ctx.attr.sdk[FipsCryptoSdkInfo]
    state = ctx.actions.declare_directory(ctx.label.name + "_state")
    activation_args = [
        _expand_sdk_path(argument, sdk.sysroot.path, state.path)
        for argument in sdk.activation_args
    ]
    ctx.actions.run(
        arguments = activation_args,
        env = {
            "LANG": "C",
            "LC_ALL": "C",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = sdk.activation_exec_tool,
        execution_requirements = {"block-network": "1"},
        inputs = depset([sdk.sysroot]),
        mnemonic = "FipsSdkPrepare",
        outputs = [state],
        progress_message = "Preparing declared OpenSSL FIPS provider state",
        tools = [sdk.activation_exec_tool],
        use_default_shell_env = False,
    )
    runtime_environment = {
        name: _expand_sdk_path(value, sdk.sysroot.path, state.path)
        for name, value in sdk.runtime_environment.items()
    }
    files = depset(direct = [sdk.sysroot, state] + sdk.runtime_files)
    return [
        DefaultInfo(
            files = files,
            runfiles = ctx.runfiles(transitive_files = files),
        ),
        HermeticRuntimeEnvironmentInfo(
            path_lists = {
                name: [value]
                for name, value in runtime_environment.items()
            },
            reentry_variables = [],
            variables = {},
        ),
    ]

_crypto_sdk_runtime_environment = rule(
    implementation = _crypto_sdk_runtime_environment_impl,
    attrs = {
        "sdk": attr.label(
            mandatory = True,
            providers = [FipsCryptoSdkInfo],
        ),
    },
)

def fips_crypto_sdk(name, crypto, visibility = None, tags = None):
    """Exports a FIPS crypto build through the normalized OTP SDK contract.

    The returned struct contains keyword arguments accepted directly by
    rules_elixir_mix's `otp_crypto_sdk` rule. No provider type is shared
    between the repositories.

    Args:
      name: SDK target name.
      crypto: Label providing FipsCryptoInfo.
      visibility: Optional visibility for exported SDK artifacts.
      tags: Optional tags applied to generated targets.

    Returns:
      A struct with an `otp_crypto_sdk` keyword-argument dictionary plus
      `openssl_tool` and `openssl_test` labels for the runnable SDK program.
    """
    common = {}
    if tags != None:
        common["tags"] = tags
    activation = name + "_activation"
    activation_exec = name + "_activation_exec"
    runtime_launcher = name + "_runtime_launcher"
    runtime_launcher_exec = name + "_runtime_launcher_exec"
    _static_go_tool(
        name = activation,
        description = "shell-free crypto activation tool",
        source = _ACTIVATION_SOURCE,
        **common
    )
    _static_go_tool(
        name = runtime_launcher,
        description = "shell-free SDK runtime launcher",
        source = _RUNTIME_LAUNCHER_SOURCE,
        **common
    )
    exec_arch = select({
        _CPU_ARM64: "arm64",
        "//conditions:default": "amd64",
    })
    _execution_static_go_tool(
        name = activation_exec,
        arch = exec_arch,
        description = "shell-free crypto activation execution tool",
        source = _ACTIVATION_SOURCE,
        **common
    )
    _execution_static_go_tool(
        name = runtime_launcher_exec,
        arch = exec_arch,
        description = "shell-free SDK runtime execution launcher",
        source = _RUNTIME_LAUNCHER_SOURCE,
        **common
    )
    sdk_args = dict(common)
    if visibility != None:
        sdk_args["visibility"] = visibility
    _crypto_sdk(
        name = name,
        activation = ":" + activation,
        activation_exec = ":" + activation_exec,
        crypto = crypto,
        runtime_launcher = ":" + runtime_launcher,
        **sdk_args
    )

    runtime_files = []
    runtime_destinations = []
    for kind, destination in _RUNTIME_LAYOUT:
        target = name + "_" + kind
        if kind not in ["activation", "runtime_launcher"]:
            _crypto_sdk_artifact(
                name = target,
                kind = kind,
                sdk = ":" + name,
                **sdk_args
            )
        runtime_files.append(":" + target)
        runtime_destinations.append(destination)

    openssl_program = name + "_openssl_program"
    openssl_runtime = name + "_openssl_runtime"
    openssl_tool = name + "_openssl_tool"
    openssl_test = name + "_openssl_test"
    _crypto_sdk_executable_artifact(
        name = openssl_program,
        kind = "openssl",
        sdk = ":" + name,
        **sdk_args
    )
    _crypto_sdk_runtime_environment(
        name = openssl_runtime,
        sdk = ":" + name,
        **sdk_args
    )
    target_runtime = select({
        _GLIBC_2_35: _TARGET_GLIBC_RUNTIME,
        "//conditions:default": _TARGET_MUSL_RUNTIME,
    })
    hermetic_target_runtime_tool(
        name = openssl_tool,
        data = ":" + openssl_runtime,
        launcher = ":" + runtime_launcher,
        program = ":" + openssl_program,
        runtime = target_runtime,
        variable = "OPENSSL",
        **sdk_args
    )
    hermetic_target_runtime_test(
        name = openssl_test,
        data = ":" + openssl_runtime,
        fixed_args = [
            "list",
            "-providers",
            "-provider",
            "fips",
            "-verbose",
        ],
        launcher = ":" + runtime_launcher,
        program = ":" + openssl_program,
        runtime = target_runtime,
        **sdk_args
    )

    return struct(
        openssl_test = ":" + openssl_test,
        openssl_tool = ":" + openssl_tool,
        otp_crypto_sdk = {
            "activation_args": [
                "--sdk-root",
                "{sysroot}",
                "fipsinstall",
                "-module",
                "{sysroot}/lib/ossl-modules/fips.so",
                "-out",
                "{activation_root}/fipsmodule.cnf",
                "-pedantic",
            ],
            "activation_exec_tool": ":" + activation_exec,
            "activation_tool": ":" + activation,
            "activation_tool_release_path": "bin/crypto-activate",
            "backend_metadata": {
                "producer": "rules_fips",
            },
            "cc_features": ["rules_fips_dynamic_executable"],
            "build_elf_interpreter": "/__bazel_hermetic_runtime__/declared-loader",
            "execution_exec_wrapper": ":" + runtime_launcher_exec,
            "execution_wrapper": ":" + runtime_launcher,
            "execution_wrapper_environment": select({
                _GLIBC_2_35: {
                    "RULES_FIPS_RUNTIME_INHIBIT_CACHE": "true",
                    "RULES_FIPS_RUNTIME_LIBRARY_PATH": "{sysroot}/lib",
                    "RULES_FIPS_RUNTIME_LOADER": "{sysroot}/lib/ld-runtime.so.1",
                    "RULES_FIPS_RUNTIME_PROGRAM": "{program}",
                },
                "//conditions:default": {
                    "RULES_FIPS_RUNTIME_LIBRARY_PATH": "{sysroot}/lib",
                    "RULES_FIPS_RUNTIME_LOADER": "{sysroot}/lib/ld-runtime.so.1",
                    "RULES_FIPS_RUNTIME_PROGRAM": "{program}",
                },
            }),
            "execution_wrapper_release_path": "bin/runtime-launch",
            "exec_support_files": [_QEMU_EXEC_SUPPORT],
            "fully_static": False,
            "linkopts": ["-ldl", "-pthread", "-lm"],
            "runtime_destinations": runtime_destinations,
            "runtime_environment": {
                "FIPS_MODULE_CONF": "{activation_root}/fipsmodule.cnf",
                "OPENSSL_CONF": "{sysroot}/ssl/openssl.cnf",
                "OPENSSL_MODULES": "{sysroot}/lib/ossl-modules",
            },
            "runtime_files": runtime_files,
            "sysroot": ":" + name,
        },
    )
