"""Pure-Starlark adapters for immutable musl execution runtimes."""

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

    sysroot_files = ctx.attr.sysroot[DefaultInfo].files
    if ctx.attr.arch == "amd64":
        loader_suffix = "/lib/ld-musl-x86_64.so.1"
    elif ctx.attr.arch == "arm64":
        loader_suffix = "/lib/ld-musl-aarch64.so.1"
    else:
        fail("unsupported musl sysroot architecture: %s" % ctx.attr.arch)

    files = depset(
        direct = [ctx.file.musl_license],
        transitive = [sysroot_files],
    )
    info = MuslSysrootInfo(
        files = files,
        license = ctx.file.musl_license,
        libc = _file_with_suffix(sysroot_files.to_list(), "/lib/libc.musl-%s.so.1" % ("x86_64" if ctx.attr.arch == "amd64" else "aarch64")),
        loader = _file_with_suffix(sysroot_files.to_list(), loader_suffix),
        revision = "1.2.6-r2",
    )
    return [
        DefaultInfo(files = files),
        info,
    ]

prebuilt_musl_sysroot = rule(
    implementation = _prebuilt_musl_sysroot_impl,
    attrs = {
        "arch": attr.string(mandatory = True, values = ["amd64", "arm64"]),
        "marker": attr.label(allow_single_file = True, mandatory = True),
        "musl_license": attr.label(allow_single_file = True, mandatory = True),
        "sysroot": attr.label(mandatory = True),
    },
    doc = "Exposes a SHA-pinned Alpine musl loader/runtime without running a build script.",
)
