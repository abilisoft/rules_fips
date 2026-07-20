"""Normalized crypto SDK exports for backend-neutral language rules."""

load(
    "//fips:providers.bzl",
    "FipsCryptoInfo",
    "FipsCryptoSdkInfo",
)

_TOOLCHAIN_TYPE = Label("//fips:toolchain_type")
_ACTIVATION_SOURCE = Label("//tools/crypto_activation:main.go")
_RUNTIME_LAUNCHER_SOURCE = Label("//tools/runtime_launcher:main.go")
_STAGER = Label("//fips/private:fips_artifact_validator")
_QEMU_AARCH64 = Label("@fips_qemu_aarch64//:usr/bin/qemu-aarch64")

_RUNTIME_LAYOUT = [
    ("activation", "bin/crypto-activate"),
    ("runtime_launcher", "bin/runtime-launch"),
    ("openssl", "bin/openssl"),
    ("provider", "lib/ossl-modules/fips.so"),
    ("config", "ssl/openssl.cnf"),
    ("loader", "lib/ld-musl.so.1"),
    ("libc", "lib/libc.musl.so.1"),
    ("manifest", "evidence/FIPS_BUILD.json"),
    ("openssl_core_license", "licenses/openssl-core-LICENSE.txt"),
    ("openssl_provider_license", "licenses/openssl-fips-provider-LICENSE.txt"),
    ("musl_license", "licenses/musl-COPYRIGHT.txt"),
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
            "-ldflags=-s -w -X main.qemuAarch64={}".format(platform.qemu_aarch64_file.path),
            "-o",
            executable.path,
            ctx.file.source.path,
        ],
        env = {
            "CGO_ENABLED": "0",
            "GOCACHE": "/proc/self/cwd/" + go_state.path + "/cache",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": goarch,
            "GOPATH": "/proc/self/cwd/" + go_state.path + "/path",
            "GOTOOLCHAIN": "local",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
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

def _crypto_sdk_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    crypto = ctx.attr.crypto[FipsCryptoInfo]
    if crypto.backend != "openssl":
        fail("the current normalized SDK implementation supports OpenSSL inputs only")

    runtime = crypto.runtime_files.to_list()
    artifacts = {
        "activation": ctx.executable.activation,
        "config": _file_named(runtime, "openssl-fips.cnf"),
        "libc": platform.musl_libc_file,
        "loader": platform.musl_loader_file,
        "manifest": crypto.manifest,
        "musl_license": platform.musl_license_file,
        "openssl": _file_named(runtime, "openssl"),
        "openssl_core_license": _file_named(runtime, "openssl-core-LICENSE.txt"),
        "openssl_provider_license": _file_named(runtime, "openssl-fips-provider-LICENSE.txt"),
        "provider": _file_named(runtime, "fips.so"),
        "runtime_launcher": ctx.executable.runtime_launcher,
    }
    libcrypto = _static_library(crypto, "libcrypto.a")
    libssl = _static_library(crypto, "libssl.a")
    sysroot = ctx.actions.declare_directory(ctx.label.name + "_sysroot")
    ctx.actions.run(
        arguments = [
            "stage-crypto-sdk",
            crypto.include_dir.path,
            libcrypto.path,
            libssl.path,
            artifacts["openssl"].path,
            artifacts["provider"].path,
            artifacts["config"].path,
            artifacts["loader"].path,
            artifacts["libc"].path,
            artifacts["activation"].path,
            sysroot.path,
        ],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.executable.stager,
        execution_requirements = {"block-network": "1"},
        inputs = depset([
            crypto.include_dir,
            libcrypto,
            libssl,
        ] + artifacts.values()),
        mnemonic = "CryptoSdkStage",
        outputs = [sysroot],
        progress_message = "Staging normalized crypto SDK for {}".format(platform.arch),
    )

    runtime_files = [artifacts[key] for key, _ in _RUNTIME_LAYOUT]
    runtime_destinations = [destination for _, destination in _RUNTIME_LAYOUT]
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
            execution_wrapper_environment = {
                "RULES_FIPS_RUNTIME_LIBRARY_PATH": "{sysroot}/lib",
                "RULES_FIPS_RUNTIME_LOADER": "{sysroot}/lib/ld-musl.so.1",
                "RULES_FIPS_RUNTIME_PROGRAM": "{program}",
            },
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
      A struct with an `otp_crypto_sdk` keyword-argument dictionary.
    """
    common = {}
    if tags != None:
        common["tags"] = tags
    activation = name + "_activation"
    runtime_launcher = name + "_runtime_launcher"
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
    sdk_args = dict(common)
    if visibility != None:
        sdk_args["visibility"] = visibility
    _crypto_sdk(
        name = name,
        activation = ":" + activation,
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

    return struct(otp_crypto_sdk = {
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
        "activation_exec_tool": ":" + activation,
        "activation_tool": ":" + activation,
        "activation_tool_release_path": "bin/crypto-activate",
        "backend_metadata": {
            "producer": "rules_fips",
        },
        "execution_exec_wrapper": ":" + runtime_launcher,
        "execution_wrapper": ":" + runtime_launcher,
        "execution_wrapper_environment": {
            "RULES_FIPS_RUNTIME_LIBRARY_PATH": "{sysroot}/lib",
            "RULES_FIPS_RUNTIME_LOADER": "{sysroot}/lib/ld-musl.so.1",
            "RULES_FIPS_RUNTIME_PROGRAM": "{program}",
        },
        "execution_wrapper_release_path": "bin/runtime-launch",
        "exec_support_files": [_QEMU_AARCH64],
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
    })
