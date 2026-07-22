"""Hermetic execution adapter for rules_rust toolchains."""

load(
    "@rules_cc//cc:action_names.bzl",
    "CPP_LINK_STATIC_LIBRARY_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//fips:providers.bzl", "TargetPkgConfigSdkInfo")
load("//fips/toolchains:runtime_tool.bzl", "hermetic_runtime_tool")

_DEFAULT_RUNTIME_LIBRARIES = Label("@fips_zlib//:libz.so.1")
_DEFAULT_RUNTIME = Label("//fips/toolchains:execution_glibc")
_DEFAULT_RUNTIME_LAUNCHER = Label("//fips/toolchains:runtime_launcher")
_RUST_TOOLCHAIN_TYPE = Label("@rules_rust//rust:toolchain")
_TOOL_FIELDS = {
    "cargo": "cargo",
    "clippy_driver": "clippy_driver",
    "llvm_cov": "llvm_cov",
    "llvm_profdata": "llvm_profdata",
    "rust_doc": "rust_doc",
    "rust_objcopy": "rust_objcopy",
    "rustc": "rustc",
    "rustfmt": "rustfmt",
}

def _merge_crate_type_flags(base, configured):
    merged = {}
    for crate_type, flags in base.items():
        merged[crate_type] = list(flags)
    for crate_type, flags in configured.items():
        merged[crate_type] = merged.get(crate_type, []) + flags
    return merged

def _execroot_path(path):
    if path.startswith("/"):
        fail("Declared tool and SDK paths must be relative to the Bazel execution root: {}".format(path))
    if path == ".":
        return "${pwd}"
    return "${pwd}/" + path

def _native_tool_path(path):
    if path.startswith("/"):
        fail("Native compiler paths must be relative to the Bazel execution root: {}".format(path))
    return path

def _rust_toolchain_adapter_impl(ctx):
    base = ctx.attr.toolchain[platform_common.ToolchainInfo]
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    compiler = cc_common.get_tool_for_action(
        action_name = C_COMPILE_ACTION_NAME,
        feature_configuration = feature_configuration,
    )
    archiver = cc_common.get_tool_for_action(
        action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
        feature_configuration = feature_configuration,
    )
    fields = {}
    for name in dir(base):
        if name not in ["to_json", "to_proto"]:
            fields[name] = getattr(base, name)

    inputs = [base.all_files]
    make_variables = dict(ctx.attr.toolchain[platform_common.TemplateVariableInfo].variables)
    for field, attribute in _TOOL_FIELDS.items():
        target = getattr(ctx.attr, attribute)
        executable = getattr(ctx.executable, attribute)
        fields[field] = executable
        inputs.extend([
            target[DefaultInfo].files,
            target[DefaultInfo].default_runfiles.files,
        ])
        variable = {
            "cargo": "CARGO",
            "rust_doc": "RUSTDOC",
            "rustc": "RUSTC",
            "rustfmt": "RUSTFMT",
        }.get(field)
        if variable:
            make_variables[variable] = executable.path

    fields["cargo_clippy"] = None
    fields["linker"] = None
    fields["linker_preference"] = "cc"
    fields["linker_type"] = None
    fields["env"] = dict(base.env)
    fields["env"].update({
        # cargo_build_script_runner joins these four tool variables to the
        # execution root before starting the build script. A ${pwd} prefix is
        # intentionally invalid here because the runner handles these values
        # before its generic environment substitution pass.
        "AR": _native_tool_path(archiver),
        "CC": _native_tool_path(compiler),
        "CXX": _native_tool_path(compiler),
        "LD": _native_tool_path(compiler),
        "RULES_RUST_SYMLINK_EXEC_ROOT": "1",
    })
    if ctx.attr.pkg_config_sdk:
        sdk = ctx.attr.pkg_config_sdk[TargetPkgConfigSdkInfo]
        inputs.append(sdk.files)
        fields["env"].update({
            "PATH": "",
            "PKG_CONFIG": _execroot_path(sdk.pkg_config.path),
            "PKG_CONFIG_ALLOW_CROSS": "1",
            "PKG_CONFIG_LIBDIR": ":".join([_execroot_path(path) for path in sdk.libdirs]),
            "PKG_CONFIG_PATH": "",
            "PKG_CONFIG_SYSROOT_DIR": _execroot_path(sdk.sysroot),
            "PKG_CONFIG_SYSTEM_INCLUDE_PATH": "",
            "PKG_CONFIG_SYSTEM_LIBRARY_PATH": "",
        })
    fields["all_files"] = depset(transitive = inputs)
    fields["extra_rustc_flags_for_crate_types"] = _merge_crate_type_flags(
        base.extra_rustc_flags_for_crate_types,
        ctx.attr.extra_rustc_flags_for_crate_types,
    )
    make_info = platform_common.TemplateVariableInfo(make_variables)
    fields["make_variables"] = make_info
    return [
        platform_common.ToolchainInfo(**fields),
        make_info,
    ]

rust_toolchain_adapter = rule(
    implementation = _rust_toolchain_adapter_impl,
    attrs = dict({
        "extra_rustc_flags_for_crate_types": attr.string_list_dict(
            default = {"bin": ["-Ctarget-feature=+crt-static"]},
            doc = "Crate-type-specific flags merged into the wrapped rules_rust toolchain.",
        ),
        "toolchain": attr.label(
            mandatory = True,
            providers = [platform_common.ToolchainInfo, platform_common.TemplateVariableInfo],
        ),
        "pkg_config_sdk": attr.label(providers = [TargetPkgConfigSdkInfo]),
    }, **{
        attribute: attr.label(mandatory = True, executable = True, cfg = "exec")
        for attribute in _TOOL_FIELDS.values()
    }),
    doc = "Re-exports a rules_rust toolchain with declared runtime wrappers and executable-only CRT flags.",
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

def _runtime_wrapper(name, program, data, library_files, runtime, launcher, relative_library_dirs, tags):
    hermetic_runtime_tool(
        name = name,
        data = data,
        launcher = launcher,
        library_files = library_files,
        program = program,
        relative_library_dirs = relative_library_dirs,
        runtime = runtime,
        tags = tags,
        variable = "RULES_FIPS_UNUSED_" + name.upper(),
    )

def fips_rust_toolchain(
        name,
        toolchain,
        tools_repository,
        exec_compatible_with,
        target_compatible_with,
        runtime = _DEFAULT_RUNTIME,
        launcher = _DEFAULT_RUNTIME_LAUNCHER,
        runtime_libraries = _DEFAULT_RUNTIME_LIBRARIES,
        pkg_config_sdk = None,
        tags = None,
        visibility = None):
    """Adapts a rules_rust toolchain to the declared GNU execution runtime.

    The target linker continues to come from Bazel's resolved C/C++ toolchain.
    Executable crates receive Rust's static CRT; shared objects, including proc
    macros, remain dynamic.

    Args:
      name: Registered toolchain target name.
      toolchain: Underlying rules_rust provider target.
      tools_repository: Apparent repository containing the Rust executables.
      exec_compatible_with: Execution-platform constraints.
      target_compatible_with: Target-platform constraints.
      runtime: Declared GNU execution runtime provider.
      launcher: Static runtime launcher.
      runtime_libraries: Declared non-libc libraries required by Rust's execution tools.
      pkg_config_sdk: Optional target_pkg_config_sdk target made available to Cargo build scripts.
      tags: Optional tags applied to generated targets.
      visibility: Optional visibility of the registered toolchain.
    """
    common = {}
    if tags != None:
        common["tags"] = tags
    wrappers = {}
    tool_labels = {
        "cargo": "cargo",
        "clippy_driver": "clippy_driver_bin",
        "llvm_cov": "llvm_cov_bin",
        "llvm_profdata": "llvm_profdata_bin",
        "rust_doc": "rustdoc",
        "rust_objcopy": "rust-objcopy",
        "rustc": "rustc",
        "rustfmt": "rustfmt_bin",
    }
    for field, target in tool_labels.items():
        wrapper = name + "_" + field
        relative_library_dirs = ["../lib"]
        if field in ["llvm_cov", "llvm_profdata", "rust_objcopy"]:
            relative_library_dirs = ["../../.."]
        _runtime_wrapper(
            name = wrapper,
            data = tools_repository + "//:rustc_lib",
            launcher = launcher,
            library_files = runtime_libraries,
            program = tools_repository + "//:" + target,
            relative_library_dirs = relative_library_dirs,
            runtime = runtime,
            tags = tags,
        )
        wrappers[field] = ":" + wrapper

    implementation = name + "_impl"
    adapter_args = dict(common, **wrappers)
    if pkg_config_sdk != None:
        adapter_args["pkg_config_sdk"] = pkg_config_sdk
    rust_toolchain_adapter(
        name = implementation,
        toolchain = toolchain,
        **adapter_args
    )
    native.toolchain(
        name = name,
        exec_compatible_with = exec_compatible_with,
        target_compatible_with = target_compatible_with,
        toolchain = ":" + implementation,
        toolchain_type = _RUST_TOOLCHAIN_TYPE,
        visibility = visibility,
        **common
    )
