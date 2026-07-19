"""Small Clang/musl C++ toolchain used by native Bazel and rules_foreign_cc."""

load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "feature",
    "tool_path",
)
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")

def _sysroot_path(marker):
    suffix = "/usr/include/stdio.h"
    if not marker.path.endswith(suffix):
        fail("musl sysroot marker must end in %s" % suffix)
    return marker.path.removesuffix(suffix)

def _fips_cc_toolchain_config_impl(ctx):
    sysroot = _sysroot_path(ctx.file.sysroot_marker)
    resource_dir = sysroot + "/usr/lib/llvm22/lib/clang/22"
    features = [
        feature(name = "supports_pic", enabled = True),
        feature(name = "supports_start_end_lib", enabled = True),
    ]
    return [
        cc_common.create_cc_toolchain_config_info(
            ctx = ctx,
            action_configs = [],
            features = features,
            cxx_builtin_include_directories = [
                resource_dir + "/include",
                sysroot + "/usr/include",
                sysroot + "/usr/include/c++/v1",
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
                tool_path(name = "ar", path = ctx.file.ar.path),
                tool_path(name = "cpp", path = ctx.file.clang.path),
                tool_path(name = "gcc", path = ctx.file.clang.path),
                tool_path(name = "gcov", path = ctx.file.nm.path),
                tool_path(name = "ld", path = ctx.file.ld.path),
                tool_path(name = "nm", path = ctx.file.nm.path),
                tool_path(name = "objdump", path = ctx.file.objdump.path),
                tool_path(name = "strip", path = ctx.file.strip.path),
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
