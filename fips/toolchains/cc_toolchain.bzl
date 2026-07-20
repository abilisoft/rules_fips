"""Small Clang/musl C++ toolchain used by native Bazel and rules_foreign_cc."""

load(
    "@rules_cc//cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
    "CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME",
    "CPP_LINK_EXECUTABLE_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
    "with_feature_set",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

def _sysroot_path(marker):
    suffix = "/usr/include/stdio.h"
    if not marker.path.endswith(suffix):
        fail("musl sysroot marker must end in %s" % suffix)
    return marker.path.removesuffix(suffix)

def _execroot_path(file):
    return "/proc/self/cwd/" + file.path

def _fips_cc_toolchain_config_impl(ctx):
    sysroot = _sysroot_path(ctx.file.sysroot_marker)
    action_sysroot = "/proc/self/cwd/" + sysroot
    resource_dir = action_sysroot + "/usr/lib/llvm22/lib/clang/22"
    compile_flags = [
        "--target=" + ctx.attr.target_triplet,
        "--sysroot=" + action_sysroot,
        "-resource-dir=" + resource_dir,
        "-B" + action_sysroot + "/usr/lib/",
        "-O2",
        "-fPIC",
    ]
    cxx_flags = [
        "-stdlib=libc++",
        "-isystem" + action_sysroot + "/usr/include/c++/v1",
    ]
    loader = "ld-musl-x86_64.so.1" if ctx.attr.arch == "x86_64" else "ld-musl-aarch64.so.1"
    link_flags = [
        "--rtlib=compiler-rt",
        "--unwindlib=libunwind",
        "-fuse-ld=" + _execroot_path(ctx.file.ld),
        "-Wl,-z,relro,-z,now",
        "-Wl,--push-state,-Bstatic",
        "-lc++",
        "-lc++abi",
        "-lunwind",
        "-Wl,--pop-state",
    ]
    dynamic_executable_flags = [
        "-Wl,--dynamic-linker=" + action_sysroot + "/lib/" + loader,
        "-Wl,-rpath," + action_sysroot + "/lib",
    ]
    features = [
        feature(name = "supports_pic", enabled = True),
        feature(name = "supports_start_end_lib", enabled = True),
        feature(
            name = "rules_fips_compile_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = [
                    C_COMPILE_ACTION_NAME,
                    CPP_COMPILE_ACTION_NAME,
                    CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
                    CPP_LINK_EXECUTABLE_ACTION_NAME,
                ],
                flag_groups = [flag_group(flags = compile_flags)],
            )],
        ),
        feature(
            name = "rules_fips_cxx_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = [
                    CPP_COMPILE_ACTION_NAME,
                    CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
                    CPP_LINK_EXECUTABLE_ACTION_NAME,
                ],
                flag_groups = [flag_group(flags = cxx_flags)],
            )],
        ),
        feature(
            name = "rules_fips_link_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = [
                    CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
                    CPP_LINK_EXECUTABLE_ACTION_NAME,
                ],
                flag_groups = [flag_group(flags = link_flags)],
            )],
        ),
        feature(
            name = "rules_fips_dynamic_executable_flags",
            enabled = True,
            flag_sets = [flag_set(
                actions = [CPP_LINK_EXECUTABLE_ACTION_NAME],
                flag_groups = [flag_group(flags = dynamic_executable_flags)],
                with_features = [with_feature_set(not_features = ["fully_static_link"])],
            )],
        ),
    ]
    return [
        cc_common.create_cc_toolchain_config_info(
            ctx = ctx,
            action_configs = [],
            features = features,
            cxx_builtin_include_directories = [
                resource_dir + "/include",
                action_sysroot + "/usr/include",
                action_sysroot + "/usr/include/c++/v1",
            ],
            toolchain_identifier = "rules-fips-clang-22-%s" % ctx.attr.arch,
            host_system_name = "local",
            target_system_name = ctx.attr.target_triplet,
            target_cpu = ctx.attr.arch,
            target_libc = "musl",
            compiler = "clang",
            abi_version = "musl",
            abi_libc_version = "musl-1.2.6",
            tool_paths = [
                tool_path(name = "ar", path = _execroot_path(ctx.file.ar)),
                tool_path(name = "cpp", path = _execroot_path(ctx.file.clang)),
                tool_path(name = "gcc", path = _execroot_path(ctx.file.clang)),
                tool_path(name = "gcov", path = _execroot_path(ctx.file.nm)),
                tool_path(name = "ld", path = _execroot_path(ctx.file.ld)),
                tool_path(name = "nm", path = _execroot_path(ctx.file.nm)),
                tool_path(name = "objdump", path = _execroot_path(ctx.file.objdump)),
                tool_path(name = "strip", path = _execroot_path(ctx.file.strip)),
            ],
        ),
    ]

fips_cc_toolchain_config = rule(
    implementation = _fips_cc_toolchain_config_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "ar": attr.label(allow_single_file = True, mandatory = True),
        "clang": attr.label(allow_single_file = True, mandatory = True),
        "ld": attr.label(allow_single_file = True, mandatory = True),
        "nm": attr.label(allow_single_file = True, mandatory = True),
        "objdump": attr.label(allow_single_file = True, mandatory = True),
        "strip": attr.label(allow_single_file = True, mandatory = True),
        "sysroot_marker": attr.label(allow_single_file = True, mandatory = True),
        "target_triplet": attr.string(mandatory = True),
    },
    provides = [CcToolchainConfigInfo],
)

def _musl_static_link_smoke_impl(ctx):
    sysroot = _sysroot_path(ctx.file.sysroot_marker)
    source = ctx.actions.declare_file(ctx.label.name + ".c")
    output = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(source, "int main(void) { return 0; }\n")
    ctx.actions.run(
        arguments = [
            "-v",
            "--target=x86_64-alpine-linux-musl",
            "--sysroot=" + sysroot,
            "-resource-dir=" + sysroot + "/usr/lib/llvm22/lib/clang/22",
            "-B" + sysroot + "/usr/lib/",
            "--rtlib=compiler-rt",
            "--unwindlib=libunwind",
            "-fuse-ld=/proc/self/cwd/" + ctx.file.ld.path,
            "-static",
            source.path,
            "-o",
            output.path,
        ],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "RULES_FIPS_EXEC_ROOT": "/proc/self/cwd",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.file.clang,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [source],
            transitive = [
                ctx.attr.clang_tools[DefaultInfo].files,
                ctx.attr.sysroot[DefaultInfo].files,
            ],
        ),
        mnemonic = "MuslStaticLinkSmoke",
        outputs = [output],
        progress_message = "Linking a static musl toolchain smoke binary",
    )
    return [DefaultInfo(files = depset([output]))]

musl_static_link_smoke = rule(
    implementation = _musl_static_link_smoke_impl,
    attrs = {
        "clang": attr.label(allow_single_file = True, mandatory = True),
        "clang_tools": attr.label(mandatory = True),
        "ld": attr.label(allow_single_file = True, mandatory = True),
        "sysroot": attr.label(mandatory = True),
        "sysroot_marker": attr.label(allow_single_file = True, mandatory = True),
    },
    doc = "Links a minimal static musl executable with the pinned LLVM toolchain.",
)
