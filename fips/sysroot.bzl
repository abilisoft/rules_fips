"""Pure-Starlark adapters for immutable musl target sysroots."""

load("//fips:providers.bzl", "MuslSysrootInfo")

_MARKER_SUFFIX = "/usr/include/stdio.h"

def _file_with_suffix(files, suffix):
    for file in files:
        if file.path.endswith(suffix):
            return file
    fail("musl sysroot does not contain %s" % suffix)

def _prebuilt_musl_sysroot_impl(ctx):
    marker = ctx.file.marker
    if not marker.path.endswith(_MARKER_SUFFIX):
        fail("musl sysroot marker must end with %s" % _MARKER_SUFFIX)

    root = marker.path.removesuffix(_MARKER_SUFFIX)
    resource_dir = root + "/usr/lib/llvm22/lib/clang/22"
    sysroot_files = ctx.attr.sysroot[DefaultInfo].files
    if ctx.attr.arch == "amd64":
        compiler_rt = root + "/usr/lib/llvm22/lib/clang/22/lib/x86_64-alpine-linux-musl/libclang_rt.builtins-x86_64.a"
        loader_suffix = "/lib/ld-musl-x86_64.so.1"
        target_triplet = "x86_64-alpine-linux-musl"
    elif ctx.attr.arch == "arm64":
        compiler_rt = root + "/usr/lib/llvm22/lib/clang/22/lib/aarch64-alpine-linux-musl/libclang_rt.builtins-aarch64.a"
        loader_suffix = "/lib/ld-musl-aarch64.so.1"
        target_triplet = "aarch64-alpine-linux-musl"
    else:
        fail("unsupported musl sysroot architecture: %s" % ctx.attr.arch)

    files = depset(
        direct = [ctx.file.compiler_rt_license, ctx.file.musl_license],
        transitive = [sysroot_files],
    )
    info = MuslSysrootInfo(
        compiler_rt = compiler_rt,
        compiler_rt_license = ctx.file.compiler_rt_license.path,
        files = files,
        license = ctx.file.musl_license,
        libc = _file_with_suffix(sysroot_files.to_list(), "/lib/libc.musl-%s.so.1" % ("x86_64" if ctx.attr.arch == "amd64" else "aarch64")),
        loader = _file_with_suffix(sysroot_files.to_list(), loader_suffix),
        revision = "1.2.6-r2",
        resource_dir = resource_dir,
        sysroot_path = root,
        target_triplet = target_triplet,
    )
    return [
        DefaultInfo(files = files),
        info,
    ]

prebuilt_musl_sysroot = rule(
    implementation = _prebuilt_musl_sysroot_impl,
    attrs = {
        "arch": attr.string(mandatory = True, values = ["amd64", "arm64"]),
        "compiler_rt_license": attr.label(allow_single_file = True, mandatory = True),
        "marker": attr.label(allow_single_file = True, mandatory = True),
        "musl_license": attr.label(allow_single_file = True, mandatory = True),
        "sysroot": attr.label(mandatory = True),
    },
    doc = "Exposes a SHA-pinned Alpine musl/libc++/compiler-rt sysroot without running a build script.",
)
