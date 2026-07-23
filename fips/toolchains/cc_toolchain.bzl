"""Hermetic Clang C/C++ toolchains for pinned musl and glibc sysroots."""

load(
    "@rules_cc//cc:action_names.bzl",
    "ALL_CC_COMPILE_ACTION_NAMES",
    "ALL_CPP_COMPILE_ACTION_NAMES",
    "CC_LINK_EXECUTABLE_ACTION_NAMES",
    "CPP20_MODULE_CODEGEN_ACTION_NAME",
    "CPP20_MODULE_COMPILE_ACTION_NAME",
    "CPP_LINK_STATIC_LIBRARY_ACTION_NAME",
    "DYNAMIC_LIBRARY_LINK_ACTION_NAMES",
    "OBJ_COPY_ACTION_NAME",
    "STRIP_ACTION_NAME",
)
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "action_config",
    "feature",
    "flag_group",
    "flag_set",
    "tool",
    "with_feature_set",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")
load("//fips:providers.bzl", "UbiRpmTreeInfo")

def _bootlin_toolchain_paths(marker, target_triplet, gcc_version):
    suffix = "/{}/sysroot/usr/include/stdio.h".format(target_triplet)
    if not marker.path.endswith(suffix):
        fail("glibc sysroot marker must end in {}".format(suffix))
    root = marker.path.removesuffix(suffix)
    return struct(
        cxx_root = root + "/" + target_triplet + "/include/c++/" + gcc_version,
        gcc_lib = root + "/lib/gcc/" + target_triplet + "/" + gcc_version,
        gcc_root = root,
        sysroot = root + "/" + target_triplet + "/sysroot",
    )

def _clang_resource_root(marker):
    suffix = "/usr/bin/clang"
    if not marker.path.endswith(suffix):
        fail("Clang resource marker must end in {}".format(suffix))
    return marker.path.removesuffix(suffix)

def _fips_cc_toolchain_config_impl(ctx, paths):
    action_sysroot = paths.sysroot
    action_gcc_root = paths.gcc_root
    action_gcc_lib = paths.gcc_lib
    action_cxx_root = paths.cxx_root
    resource_root = _clang_resource_root(ctx.file.resource_marker)
    resource_dir = resource_root + "/usr/lib/llvm22/lib/clang/22"
    compile_flags = [
        "--target=" + ctx.attr.target_triplet,
        "--sysroot=" + action_sysroot,
        "--gcc-toolchain=" + action_gcc_root,
        "-resource-dir=" + resource_dir,
        "-O2",
        "-fPIC",
    ]

    # Bazel has shared executable/dynamic-library link action names for C and
    # C++. Drive those links with Clang's C++ mode so declared libstdc++ is
    # selected without relying on an argv[0] symlink named clang++.
    cxx_driver_flags = [
        "--driver-mode=g++",
        "-stdlib=libstdc++",
    ]
    cxx_compile_flags = cxx_driver_flags + [
        "-isystem",
        action_cxx_root,
        "-isystem",
        action_cxx_root + "/" + ctx.attr.target_triplet,
        "-isystem",
        action_cxx_root + "/backward",
    ]
    link_flags = [
        # The execution-architecture Clang package cannot infer a target
        # compiler-rt path for Bootlin's cross triples. Pass the declared
        # target archive after Bazel's objects and leave libgcc as the
        # driver's declared fallback for symbols outside compiler-rt.
        "--rtlib=libgcc",
        "--unwindlib=libgcc",
        "-Wno-unused-command-line-argument",
        # The declared ld.lld launcher is a sibling of Clang. The launcher
        # supplies -ccc-install-dir, so Clang resolves this name without PATH
        # lookup or an execroot-dependent path.
        "-fuse-ld=lld",
        "-L" + action_gcc_lib,
        "-Wl,-z,relro,-z,now",
        ctx.file.compiler_runtime.path,
    ]
    if ctx.file.ssp_runtime:
        link_flags.append("-L" + ctx.file.ssp_runtime.dirname)
    compiler_actions = ALL_CC_COMPILE_ACTION_NAMES + [
        CPP20_MODULE_COMPILE_ACTION_NAME,
        CPP20_MODULE_CODEGEN_ACTION_NAME,
    ]
    cxx_compile_actions = ALL_CPP_COMPILE_ACTION_NAMES + [
        CPP20_MODULE_COMPILE_ACTION_NAME,
        CPP20_MODULE_CODEGEN_ACTION_NAME,
    ]
    link_actions = CC_LINK_EXECUTABLE_ACTION_NAMES + DYNAMIC_LIBRARY_LINK_ACTION_NAMES
    compile_and_link_actions = compiler_actions + CC_LINK_EXECUTABLE_ACTION_NAMES + DYNAMIC_LIBRARY_LINK_ACTION_NAMES
    static_compiler_runtime_flags = [
        "-static-libgcc",
        "-static-libstdc++",
    ] if ctx.attr.static_compiler_runtime else []
    features = [
        feature(name = "supports_pic", enabled = True),
        feature(name = "supports_start_end_lib", enabled = True),
        feature(
            name = "rules_fips_compile_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = compile_and_link_actions,
                flag_groups = [flag_group(flags = compile_flags)],
            )],
        ),
        feature(
            name = "rules_fips_cxx_compile_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = cxx_compile_actions,
                flag_groups = [flag_group(flags = cxx_compile_flags)],
            )],
        ),
        feature(
            name = "rules_fips_cxx_link_driver_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = link_actions,
                flag_groups = [flag_group(flags = cxx_driver_flags)],
            )],
        ),
        feature(
            name = "rules_fips_link_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = link_actions,
                flag_groups = [flag_group(flags = link_flags)],
            )],
        ),
        feature(
            name = "rules_fips_shared_runtime",
            enabled = True,
            flag_sets = [flag_set(
                actions = DYNAMIC_LIBRARY_LINK_ACTION_NAMES,
                flag_groups = [flag_group(flags = static_compiler_runtime_flags + [
                    # Loadable NIFs and proc macros must not acquire a missing
                    # dependency from the worker's default library paths.
                    "-Wl,-z,nodefaultlib",
                ])],
            )],
        ),
        feature(
            name = "rules_fips_static_executables",
            enabled = True,
            flag_sets = [flag_set(
                actions = CC_LINK_EXECUTABLE_ACTION_NAMES,
                flag_groups = [flag_group(flags = ["-static"])],
                with_features = [with_feature_set(not_features = ["rules_fips_dynamic_executable"])],
            )],
        ),
    ]
    if ctx.attr.dynamic_loader:
        features.extend([
            feature(
                name = "rules_fips_dynamic_executables",
                enabled = True,
                flag_sets = [flag_set(
                    actions = CC_LINK_EXECUTABLE_ACTION_NAMES,
                    flag_groups = [flag_group(flags = static_compiler_runtime_flags + [
                        # A dynamic executable is never started directly. Its
                        # declared runtime wrapper invokes the packaged loader
                        # with an explicit library path. Keep direct exec
                        # fail-closed and keep execroot paths out of the ELF.
                        "-Wl,--dynamic-linker=/__bazel_hermetic_runtime__/declared-loader",
                        # Tell glibc's loader to reject cache/default-directory
                        # resolution when the declared library closure is
                        # incomplete. musl ignores this ELF flag; the static
                        # launcher validates the same closure before exec.
                        "-Wl,-z,nodefaultlib",
                    ])],
                    with_features = [with_feature_set(features = ["rules_fips_dynamic_executable"])],
                )],
            ),
            feature(name = "rules_fips_dynamic_executable"),
        ])

    compile_implies = [
        "legacy_compile_flags",
        "user_compile_flags",
        "sysroot",
        "unfiltered_compile_flags",
        "compiler_input_flags",
        "compiler_output_flags",
    ]
    executable_link_implies = [
        "strip_debug_symbols",
        "linkstamps",
        "output_execpath_flags",
        "runtime_library_search_directories",
        "library_search_directories",
        "libraries_to_link",
        "force_pic_flags",
        "user_link_flags",
        "legacy_link_flags",
        "linker_param_file",
        "fission_support",
        "sysroot",
    ]
    dynamic_link_implies = [
        "build_interface_libraries",
        "dynamic_library_linker_tool",
        "strip_debug_symbols",
        "shared_flag",
        "linkstamps",
        "output_execpath_flags",
        "runtime_library_search_directories",
        "library_search_directories",
        "libraries_to_link",
        "user_link_flags",
        "legacy_link_flags",
        "linker_param_file",
        "fission_support",
        "sysroot",
    ]
    action_configs = [
        action_config(
            action_name = action_name,
            implies = compile_implies,
            tools = [tool(tool = ctx.file.clang)],
        )
        for action_name in compiler_actions
    ] + [
        action_config(
            action_name = action_name,
            implies = executable_link_implies,
            tools = [tool(tool = ctx.file.clang)],
        )
        for action_name in CC_LINK_EXECUTABLE_ACTION_NAMES
    ] + [
        action_config(
            action_name = action_name,
            implies = dynamic_link_implies,
            tools = [tool(tool = ctx.file.clang)],
        )
        for action_name in DYNAMIC_LIBRARY_LINK_ACTION_NAMES
    ] + [
        action_config(
            action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
            implies = ["archiver_flags", "linker_param_file"],
            tools = [tool(tool = ctx.file.ar)],
        ),
        action_config(
            action_name = OBJ_COPY_ACTION_NAME,
            tools = [tool(tool = ctx.file.objcopy)],
        ),
        action_config(
            action_name = STRIP_ACTION_NAME,
            flag_sets = [flag_set(flag_groups = [
                flag_group(flags = ["-S", "-p", "-o", "%{output_file}"]),
                flag_group(iterate_over = "stripopts", flags = ["%{stripopts}"]),
                flag_group(flags = ["%{input_file}"]),
            ])],
            tools = [tool(tool = ctx.file.strip)],
        ),
    ]
    return [cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        action_configs = action_configs,
        features = features,
        cxx_builtin_include_directories = [
            resource_dir + "/include",
            action_sysroot + "/usr/include",
            action_cxx_root,
            action_cxx_root + "/" + ctx.attr.target_triplet,
            action_cxx_root + "/backward",
        ],
        toolchain_identifier = "rules-fips-clang-22-{}-{}".format(ctx.attr.libc, ctx.attr.arch),
        host_system_name = "local",
        target_system_name = ctx.attr.target_triplet,
        target_cpu = ctx.attr.arch,
        target_libc = ctx.attr.libc,
        compiler = "clang",
        abi_version = ctx.attr.abi_version,
        abi_libc_version = ctx.attr.abi_libc_version,
        tool_paths = [],
    )]

def _fips_bootlin_cc_toolchain_config_impl(ctx):
    paths = _bootlin_toolchain_paths(ctx.file.sysroot_marker, ctx.attr.target_triplet, ctx.attr.gcc_version)
    return _fips_cc_toolchain_config_impl(ctx, paths)

def _fips_ubi_cc_toolchain_config_impl(ctx):
    root = ctx.attr.sysroot[UbiRpmTreeInfo].root
    return _fips_cc_toolchain_config_impl(ctx, struct(
        cxx_root = root + "/usr/include/c++/" + ctx.attr.gcc_version,
        gcc_lib = root + "/usr/lib/gcc/" + ctx.attr.target_triplet + "/" + ctx.attr.gcc_version,
        gcc_root = root + "/usr",
        sysroot = root,
    ))

fips_bootlin_cc_toolchain_config = rule(
    implementation = _fips_bootlin_cc_toolchain_config_impl,
    attrs = {
        "abi_libc_version": attr.string(mandatory = True),
        "abi_version": attr.string(mandatory = True),
        "arch": attr.string(mandatory = True),
        "ar": attr.label(allow_single_file = True, mandatory = True),
        "clang": attr.label(allow_single_file = True, mandatory = True),
        "compiler_runtime": attr.label(allow_single_file = [".a"], mandatory = True),
        "dynamic_loader": attr.string(),
        "gcc_version": attr.string(mandatory = True),
        "ld": attr.label(allow_single_file = True, mandatory = True),
        "libc": attr.string(mandatory = True),
        "nm": attr.label(allow_single_file = True, mandatory = True),
        "objcopy": attr.label(allow_single_file = True, mandatory = True),
        "objdump": attr.label(allow_single_file = True, mandatory = True),
        "resource_marker": attr.label(allow_single_file = True, mandatory = True),
        "strip": attr.label(allow_single_file = True, mandatory = True),
        "ssp_runtime": attr.label(allow_single_file = [".a"]),
        "static_compiler_runtime": attr.bool(default = True),
        "sysroot_marker": attr.label(allow_single_file = True, mandatory = True),
        "target_triplet": attr.string(mandatory = True),
    },
    provides = [CcToolchainConfigInfo],
)

fips_ubi_cc_toolchain_config = rule(
    implementation = _fips_ubi_cc_toolchain_config_impl,
    attrs = {
        "abi_libc_version": attr.string(mandatory = True),
        "abi_version": attr.string(mandatory = True),
        "arch": attr.string(mandatory = True),
        "ar": attr.label(allow_single_file = True, mandatory = True),
        "clang": attr.label(allow_single_file = True, mandatory = True),
        "compiler_runtime": attr.label(allow_single_file = [".a"], mandatory = True),
        "dynamic_loader": attr.string(),
        "gcc_version": attr.string(mandatory = True),
        "ld": attr.label(allow_single_file = True, mandatory = True),
        "libc": attr.string(mandatory = True),
        "nm": attr.label(allow_single_file = True, mandatory = True),
        "objcopy": attr.label(allow_single_file = True, mandatory = True),
        "objdump": attr.label(allow_single_file = True, mandatory = True),
        "resource_marker": attr.label(allow_single_file = True, mandatory = True),
        "ssp_runtime": attr.label(allow_single_file = [".a"]),
        "static_compiler_runtime": attr.bool(default = True),
        "strip": attr.label(allow_single_file = True, mandatory = True),
        "sysroot": attr.label(mandatory = True, providers = [UbiRpmTreeInfo]),
        "target_triplet": attr.string(mandatory = True),
    },
    provides = [CcToolchainConfigInfo],
)

fips_glibc_cc_toolchain_config = fips_bootlin_cc_toolchain_config
