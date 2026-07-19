"""Small Clang/musl C++ toolchain used by native Bazel and rules_foreign_cc."""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/toolchains:cc_toolchain_config_info.bzl", "CcToolchainConfigInfo")
load(
    "@rules_cc//cc:cc_toolchain_config_lib.bzl",
    "feature",
    "tool_path",
)

def _single_root(target, description):
    files = target[DefaultInfo].files.to_list()
    if len(files) != 1:
        fail("%s must provide exactly one directory" % description)
    return files[0].path

def _sysroot_path(marker):
    suffix = "/usr/include/stdio.h"
    if not marker.path.endswith(suffix):
        fail("musl sysroot marker must end in %s" % suffix)
    return marker.path.removesuffix(suffix)

def _fips_cc_toolchain_config_impl(ctx):
    clang = _single_root(ctx.attr.clang, "pinned LLVM archive")
    sysroot = _sysroot_path(ctx.file.sysroot_marker)
    resource_dir = clang + "/lib/clang/22"
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
                tool_path(name = "ar", path = clang + "/bin/llvm-ar"),
                tool_path(name = "cpp", path = clang + "/bin/clang"),
                tool_path(name = "gcc", path = clang + "/bin/clang"),
                tool_path(name = "gcov", path = clang + "/bin/llvm-nm"),
                tool_path(name = "ld", path = clang + "/bin/ld.lld"),
                tool_path(name = "nm", path = clang + "/bin/llvm-nm"),
                tool_path(name = "objdump", path = clang + "/bin/llvm-objdump"),
                tool_path(name = "strip", path = clang + "/bin/llvm-strip"),
            ],
        ),
    ]

fips_cc_toolchain_config = rule(
    implementation = _fips_cc_toolchain_config_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "clang": attr.label(mandatory = True),
        "sysroot_marker": attr.label(allow_single_file = True, mandatory = True),
        "target_triplet": attr.string(mandatory = True),
    },
    provides = [CcToolchainConfigInfo],
)
