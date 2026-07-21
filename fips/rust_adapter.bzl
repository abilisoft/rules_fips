"""Hermetic execution adapter for rules_rust toolchains."""

load("//fips/toolchains:runtime_tool.bzl", "hermetic_runtime_tool")

_DEFAULT_RUNTIME_LIBRARIES = Label("@fips_zlib//:libz.so.1")

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

def _rust_toolchain_adapter_impl(ctx):
    base = ctx.attr.toolchain[platform_common.ToolchainInfo]
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

    fields["all_files"] = depset(transitive = inputs)
    fields["cargo_clippy"] = None
    fields["linker"] = None
    fields["linker_preference"] = "cc"
    fields["linker_type"] = None
    fields["env"] = dict(base.env)
    fields["env"]["RULES_RUST_SYMLINK_EXEC_ROOT"] = "1"
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
    }, **{
        attribute: attr.label(mandatory = True, executable = True, cfg = "exec")
        for attribute in _TOOL_FIELDS.values()
    }),
    doc = "Re-exports a rules_rust toolchain with declared runtime wrappers and executable-only CRT flags.",
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
        runtime = "//fips/toolchains:execution_glibc",
        launcher = "//fips/toolchains:runtime_launcher",
        runtime_libraries = _DEFAULT_RUNTIME_LIBRARIES,
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
    rust_toolchain_adapter(
        name = implementation,
        toolchain = toolchain,
        **dict(common, **wrappers)
    )
    native.toolchain(
        name = name,
        exec_compatible_with = exec_compatible_with,
        target_compatible_with = target_compatible_with,
        toolchain = ":" + implementation,
        toolchain_type = "@rules_rust//rust:toolchain",
        visibility = visibility,
        **common
    )
