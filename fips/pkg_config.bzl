"""Declared target pkg-config SDKs for Cargo build scripts."""

load("//fips:providers.bzl", "TargetPkgConfigSdkInfo")

def _relative_path(value, attribute, allow_dot = False):
    if not value or value.startswith("/"):
        fail("{} must be a non-empty relative path".format(attribute))
    if value == ".":
        if allow_dot:
            return value
        fail("{} may not be '.'".format(attribute))
    for component in value.split("/"):
        if component in ["", ".", ".."]:
            fail("{} must be normalized and may not contain empty, '.' or '..' components".format(attribute))
    return value

def _root_from_marker(marker, marker_relative_path):
    suffix = "/" + marker_relative_path
    if marker.path == marker_relative_path:
        return "."
    if not marker.path.endswith(suffix):
        fail(
            "sysroot_marker {} does not end with sysroot_marker_relative_path {}".format(
                marker.path,
                marker_relative_path,
            ),
        )
    return marker.path[:-len(suffix)]

def _join(root, relative):
    if relative == ".":
        return root
    if root == ".":
        return relative
    return root + "/" + relative

def _target_pkg_config_sdk_impl(ctx):
    has_sysroot = ctx.attr.sysroot != None
    has_marker = ctx.file.sysroot_marker != None or bool(ctx.attr.sysroot_marker_relative_path)
    if has_sysroot == has_marker:
        fail("exactly one of sysroot or the sysroot_marker pair must be declared")

    direct_files = []
    transitive_files = []
    if has_sysroot:
        sysroot_files = ctx.attr.sysroot[DefaultInfo].files.to_list()
        if len(sysroot_files) != 1 or not sysroot_files[0].is_directory:
            fail("sysroot must expose exactly one declared directory artifact")
        sysroot_file = sysroot_files[0]
        sysroot = sysroot_file.path
        direct_files.append(sysroot_file)
        transitive_files.append(ctx.attr.sysroot[DefaultInfo].default_runfiles.files)
    else:
        if ctx.file.sysroot_marker == None or not ctx.attr.sysroot_marker_relative_path:
            fail("sysroot_marker and sysroot_marker_relative_path must be declared together")
        marker_relative_path = _relative_path(
            ctx.attr.sysroot_marker_relative_path,
            "sysroot_marker_relative_path",
        )
        sysroot = _root_from_marker(ctx.file.sysroot_marker, marker_relative_path)
        direct_files.append(ctx.file.sysroot_marker)

    libdirs = [
        _join(sysroot, _relative_path(path, "libdirs", allow_dot = True))
        for path in ctx.attr.libdirs
    ]
    if not libdirs:
        fail("libdirs must declare at least one pkg-config metadata directory")

    transitive_files.extend([
        ctx.attr.pkg_config[DefaultInfo].files,
        ctx.attr.pkg_config[DefaultInfo].default_runfiles.files,
    ])
    transitive_files.extend([target[DefaultInfo].files for target in ctx.attr.sdk_files])
    files = depset(
        direct = [ctx.executable.pkg_config] + direct_files,
        transitive = transitive_files,
    )
    return [
        DefaultInfo(files = files),
        TargetPkgConfigSdkInfo(
            files = files,
            libdirs = libdirs,
            pkg_config = ctx.executable.pkg_config,
            sysroot = sysroot,
        ),
    ]

target_pkg_config_sdk = rule(
    implementation = _target_pkg_config_sdk_impl,
    attrs = {
        "libdirs": attr.string_list(
            mandatory = True,
            doc = "Normalized paths from the target SDK root to directories containing .pc files.",
        ),
        "pkg_config": attr.label(
            cfg = "exec",
            default = Label("//fips/toolchains:pkgconf"),
            doc = "Declared pkg-config-compatible executable built for the execution platform.",
            executable = True,
        ),
        "sdk_files": attr.label_list(
            allow_files = True,
            doc = "Complete target SDK closure: .pc files, headers, libraries, and supporting data.",
        ),
        "sysroot": attr.label(
            doc = "Rule-produced target SDK exposing exactly one declared directory artifact.",
        ),
        "sysroot_marker": attr.label(
            allow_single_file = True,
            doc = "Declared SDK file used to derive the execroot-relative sysroot.",
        ),
        "sysroot_marker_relative_path": attr.string(
            doc = "Normalized path from the SDK root to sysroot_marker.",
        ),
    },
    doc = "Packages a declared target SDK and execution pkg-config tool without host discovery.",
)
