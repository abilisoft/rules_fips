"""Architecture toolchains used by rules_fips build actions."""

load(
    "//fips:providers.bzl",
    "FipsBootstrapPlatformInfo",
    "FipsPlatformInfo",
    "MuslSysrootInfo",
)

def _single_tree(target, description):
    roots = target[DefaultInfo].files.to_list()
    if len(roots) != 1:
        fail("%s must expose exactly one source directory" % description)
    return roots[0], target[DefaultInfo].files

def _sysroot_from_marker(marker):
    suffix = "/usr/include/stdio.h"
    if not marker.path.endswith(suffix):
        fail("bootstrap sysroot marker must end with %s" % suffix)
    return marker.path.removesuffix(suffix)

def _clang_values(ctx):
    root, files = _single_tree(ctx.attr.clang, "pinned Clang archive")
    return struct(
        cc = root.path + "/bin/clang",
        cxx = root.path + "/bin/clang++",
        files = files,
        llvm_ar = root.path + "/bin/llvm-ar",
        llvm_ranlib = root.path + "/bin/llvm-ranlib",
        llvm_readelf = root.path + "/bin/llvm-readelf",
    )

def _archive_tool(target, description, suffix):
    root, files = _single_tree(target, description)
    return root.path + suffix, files

def _file_named(target, basename, description):
    files = target[DefaultInfo].files
    for file in files.to_list():
        if file.basename == basename:
            return file, files
    fail("%s did not provide %s" % (description, basename))

def _fips_bootstrap_platform_toolchain_impl(ctx):
    clang = _clang_values(ctx)
    cmake_bin, cmake_files = _archive_tool(
        ctx.attr.cmake,
        "pinned CMake archive",
        "/bin/cmake",
    )
    info = FipsBootstrapPlatformInfo(
        arch = ctx.attr.arch,
        clang_cc = clang.cc,
        clang_cxx = clang.cxx,
        clang_files = clang.files,
        cmake_bin = cmake_bin,
        cmake_files = cmake_files,
        glibc_sysroot_files = ctx.attr.glibc_sysroot[DefaultInfo].files,
        glibc_sysroot_path = _sysroot_from_marker(ctx.file.glibc_sysroot_marker),
        gnu_triplet = ctx.attr.gnu_triplet,
        llvm_ar = clang.llvm_ar,
        llvm_ranlib = clang.llvm_ranlib,
        llvm_readelf = clang.llvm_readelf,
        musl_triplet = ctx.attr.musl_triplet,
    )
    return [
        info,
        platform_common.ToolchainInfo(bootstrap = info),
    ]

fips_bootstrap_platform_toolchain = rule(
    implementation = _fips_bootstrap_platform_toolchain_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "clang": attr.label(mandatory = True),
        "cmake": attr.label(mandatory = True),
        "glibc_sysroot": attr.label(mandatory = True),
        "glibc_sysroot_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "gnu_triplet": attr.string(mandatory = True),
        "musl_triplet": attr.string(mandatory = True),
    },
    doc = "Describes native, pinned tools used to bootstrap one musl target.",
)

def _fips_platform_toolchain_impl(ctx):
    clang = _clang_values(ctx)
    build_compiler_rt, build_compiler_rt_files = _file_named(
        ctx.attr.build_compiler_rt,
        "libclang_rt.builtins.a",
        "native bootstrap compiler-rt",
    )
    cmake_bin, cmake_files = _archive_tool(
        ctx.attr.cmake,
        "pinned CMake archive",
        "/bin/cmake",
    )
    go_bin, go_files = _archive_tool(
        ctx.attr.go,
        "pinned Go archive",
        "/bin/go",
    )
    musl = ctx.attr.musl[MuslSysrootInfo]
    info = FipsPlatformInfo(
        arch = ctx.attr.arch,
        boringssl_processor = ctx.attr.boringssl_processor,
        build_compiler_rt_files = build_compiler_rt_files,
        build_compiler_rt_path = build_compiler_rt.path,
        build_sysroot_files = ctx.attr.build_glibc_sysroot[DefaultInfo].files,
        build_sysroot_path = _sysroot_from_marker(ctx.file.build_glibc_sysroot_marker),
        build_triplet = ctx.attr.build_triplet,
        clang_cc = clang.cc,
        clang_cxx = clang.cxx,
        clang_files = clang.files,
        cmake_bin = cmake_bin,
        cmake_files = cmake_files,
        compiler_rt_license_path = musl.compiler_rt_license,
        compiler_rt_path = musl.compiler_rt,
        go_bin = go_bin,
        go_files = go_files,
        gnu_triplet = ctx.attr.gnu_triplet,
        libc = "musl",
        llvm_ar = clang.llvm_ar,
        llvm_ranlib = clang.llvm_ranlib,
        llvm_readelf = clang.llvm_readelf,
        musl_revision = musl.revision,
        musl_triplet = musl.target_triplet,
        openssl_target = ctx.attr.openssl_target,
        sysroot_files = depset([musl.sysroot]),
        sysroot_path = musl.sysroot.path,
    )
    return [
        info,
        platform_common.ToolchainInfo(fips = info),
    ]

fips_platform_toolchain = rule(
    implementation = _fips_platform_toolchain_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "boringssl_processor": attr.string(mandatory = True),
        "build_compiler_rt": attr.label(
            cfg = "exec",
            mandatory = True,
        ),
        "build_glibc_sysroot": attr.label(mandatory = True),
        "build_glibc_sysroot_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "build_triplet": attr.string(mandatory = True),
        "clang": attr.label(mandatory = True),
        "cmake": attr.label(mandatory = True),
        "go": attr.label(mandatory = True),
        "gnu_triplet": attr.string(mandatory = True),
        "musl": attr.label(
            mandatory = True,
            providers = [MuslSysrootInfo],
        ),
        "openssl_target": attr.string(mandatory = True),
    },
    doc = "Describes one fully static musl Linux target supported by rules_fips.",
)
