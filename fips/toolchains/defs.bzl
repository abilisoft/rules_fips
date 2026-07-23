"""Architecture toolchains used by rules_fips build actions."""

load(
    "//fips:providers.bzl",
    "FipsPlatformInfo",
    "HermeticRuntimeInfo",
    "UbiRpmTreeInfo",
)

_RUNTIME_STAGER = Label("//fips/private:fips_artifact_validator")

def _single_tree(target, description):
    roots = target[DefaultInfo].files.to_list()
    if len(roots) != 1:
        fail("%s must expose exactly one source directory" % description)
    return roots[0], target[DefaultInfo].files

def _clang_values(ctx):
    return struct(
        files = ctx.attr.clang_tools[DefaultInfo].files,
        llvm_nm = ctx.file.nm.path,
        llvm_ranlib = ctx.file.ranlib.path,
        llvm_readelf = ctx.file.readelf.path,
    )

def _archive_tool(target, description, suffix):
    root, files = _single_tree(target, description)
    return root.path + suffix, files

def _stage_runtime_entries(ctx, entries):
    staged = []
    arguments = ["stage-runtime"]
    for entry in entries:
        output = ctx.actions.declare_file(ctx.label.name + "_runtime/" + entry.destination)
        arguments.extend([entry.file.path, output.path])
        staged.append(struct(destination = entry.destination, file = output))
    ctx.actions.run(
        arguments = arguments,
        env = {
            "LANG": "C",
            "LC_ALL": "C",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.executable._runtime_stager,
        execution_requirements = {"block-network": "1"},
        inputs = [entry.file for entry in entries],
        outputs = [entry.file for entry in staged],
        mnemonic = "RuntimeStage",
        progress_message = "Copying declared {} {} runtime".format(ctx.attr.libc, ctx.attr.arch),
    )
    return staged

def _bootlin_root(marker, target_triplet):
    suffix = "/{}/sysroot/usr/include/stdio.h".format(target_triplet)
    if not marker.path.endswith(suffix):
        fail("Bootlin sysroot marker must end in {}".format(suffix))
    return marker.path.removesuffix(suffix)

def _runtime_file(files, sysroot, basename):
    for directory in ["lib", "usr/lib", "lib64", "usr/lib64"]:
        preferred = sysroot + "/" + directory + "/" + basename
        matches = [file for file in files if file.path == preferred]
        if len(matches) == 1:
            return matches[0]
    matches = [
        file
        for file in files
        if file.basename == basename and file.path.startswith(sysroot + "/")
    ]
    if not matches:
        matches = [file for file in files if file.basename == basename]
    if len(matches) != 1:
        fail("expected one declared {} runtime file below {}, got {}".format(basename, sysroot, matches))
    return matches[0]

def _bootlin_runtime_entries(ctx, files):
    file_list = files.to_list()
    root = _bootlin_root(ctx.file.sysroot_marker, ctx.attr.target_triplet)
    sysroot = root + "/" + ctx.attr.target_triplet + "/sysroot"
    loader_file = _runtime_file(file_list, sysroot, ctx.attr.loader)
    runtime_entries = [
        struct(destination = "ld-runtime.so.1", file = loader_file),
        # Some libc objects declare their loader's canonical SONAME in
        # DT_NEEDED. Preserve that name beside the normalized launcher entry.
        struct(destination = ctx.attr.loader, file = loader_file),
    ]
    if ctx.attr.libc == "musl":
        # musl's loader and libc are the same DSO; linked objects request its
        # libc.so SONAME even though the installed loader has an arch name.
        runtime_entries.append(struct(destination = "libc.so", file = loader_file))
    for name in ctx.attr.runtime_libraries:
        runtime_entries.append(struct(
            destination = name,
            file = _runtime_file(file_list, sysroot, name),
        ))
    return _stage_runtime_entries(ctx, runtime_entries)

def _fips_bootlin_platform_toolchain_impl(ctx):
    clang = _clang_values(ctx)
    go_bin, go_files = _archive_tool(
        ctx.attr.go,
        "pinned Go archive",
        "/bin/go",
    )
    files = ctx.attr.sysroot[DefaultInfo].files
    runtime_entries = _bootlin_runtime_entries(ctx, files)
    libc_license = ctx.file.libc_license
    qemu_aarch64_file = ctx.file.qemu_aarch64 if ctx.attr.qemu_aarch64 else None
    qemu_aarch64_files = ctx.attr.qemu_aarch64[DefaultInfo].files if ctx.attr.qemu_aarch64 else depset()
    info = FipsPlatformInfo(
        arch = ctx.attr.arch,
        clang_files = clang.files,
        go_bin = go_bin,
        go_files = go_files,
        libc = ctx.attr.libc,
        libc_license_file = libc_license,
        libc_runtime_entries = runtime_entries,
        libc_runtime_files = depset([entry.file for entry in runtime_entries]),
        libc_version = ctx.attr.libc_version,
        llvm_nm = clang.llvm_nm,
        llvm_ranlib = clang.llvm_ranlib,
        llvm_readelf = clang.llvm_readelf,
        openssl_target = ctx.attr.openssl_target,
        qemu_aarch64_file = qemu_aarch64_file,
        qemu_aarch64_files = qemu_aarch64_files,
        sysroot_files = files,
    )
    return [
        info,
        platform_common.ToolchainInfo(fips = info),
    ]

def _fips_bootlin_runtime_impl(ctx):
    files = ctx.attr.sysroot[DefaultInfo].files
    runtime_entries = _bootlin_runtime_entries(ctx, files)
    runtime_files = depset([entry.file for entry in runtime_entries])
    return [
        DefaultInfo(files = runtime_files),
        HermeticRuntimeInfo(
            libc_runtime_entries = runtime_entries,
            libc_runtime_files = runtime_files,
        ),
    ]

def _fips_ubi_platform_toolchain_impl(ctx):
    clang = _clang_values(ctx)
    go_bin, go_files = _archive_tool(
        ctx.attr.go,
        "pinned Go archive",
        "/bin/go",
    )
    sysroot = ctx.attr.sysroot[UbiRpmTreeInfo]
    entries = [
        struct(destination = "ld-runtime.so.1", source = ctx.attr.loader_path),
        struct(destination = ctx.attr.loader, source = ctx.attr.loader_path),
    ] + [
        struct(destination = destination, source = source)
        for destination, source in sorted(ctx.attr.runtime_libraries.items())
    ]
    staged = []
    arguments = ["stage-runtime"]
    for entry in entries:
        output = ctx.actions.declare_file(ctx.label.name + "_runtime/" + entry.destination)
        arguments.extend([sysroot.root + "/" + entry.source, output.path])
        staged.append(struct(destination = entry.destination, file = output))
    libc_license = ctx.actions.declare_file(ctx.label.name + "_runtime/licenses/glibc-LICENSE.txt")
    arguments.extend([sysroot.root + "/" + ctx.attr.libc_license_path, libc_license.path])
    ctx.actions.run(
        arguments = arguments,
        env = {
            "LANG": "C",
            "LC_ALL": "C",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.executable._runtime_stager,
        execution_requirements = {"block-network": "1"},
        inputs = sysroot.files,
        mnemonic = "UbiRuntimeStage",
        outputs = [entry.file for entry in staged] + [libc_license],
        progress_message = "Staging declared UBI 10 {} runtime".format(ctx.attr.arch),
    )
    qemu_aarch64_file = ctx.file.qemu_aarch64 if ctx.attr.qemu_aarch64 else None
    qemu_aarch64_files = ctx.attr.qemu_aarch64[DefaultInfo].files if ctx.attr.qemu_aarch64 else depset()
    runtime_files = depset([entry.file for entry in staged])
    info = FipsPlatformInfo(
        arch = ctx.attr.arch,
        clang_files = clang.files,
        go_bin = go_bin,
        go_files = go_files,
        libc = "glibc",
        libc_license_file = libc_license,
        libc_runtime_entries = staged,
        libc_runtime_files = runtime_files,
        libc_version = "2.39",
        llvm_nm = clang.llvm_nm,
        llvm_ranlib = clang.llvm_ranlib,
        llvm_readelf = clang.llvm_readelf,
        openssl_target = ctx.attr.openssl_target,
        qemu_aarch64_file = qemu_aarch64_file,
        qemu_aarch64_files = qemu_aarch64_files,
        sysroot_files = sysroot.files,
    )
    return [
        info,
        platform_common.ToolchainInfo(fips = info),
    ]

fips_bootlin_runtime = rule(
    implementation = _fips_bootlin_runtime_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "libc": attr.string(mandatory = True, values = ["glibc", "musl"]),
        "loader": attr.string(mandatory = True),
        "runtime_libraries": attr.string_list(),
        "sysroot": attr.label(mandatory = True),
        "sysroot_marker": attr.label(allow_single_file = True, mandatory = True),
        "target_triplet": attr.string(mandatory = True),
        "_runtime_stager": attr.label(
            default = _RUNTIME_STAGER,
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Stages a target libc runtime without pulling compiler-only platform inputs.",
)

fips_bootlin_platform_toolchain = rule(
    implementation = _fips_bootlin_platform_toolchain_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "clang_tools": attr.label(mandatory = True),
        "go": attr.label(mandatory = True),
        "libc": attr.string(mandatory = True, values = ["glibc", "musl"]),
        "libc_version": attr.string(mandatory = True),
        "libc_license": attr.label(allow_single_file = True, mandatory = True),
        "loader": attr.string(mandatory = True),
        "nm": attr.label(allow_single_file = True, mandatory = True),
        "openssl_target": attr.string(mandatory = True),
        "qemu_aarch64": attr.label(allow_single_file = True),
        "ranlib": attr.label(allow_single_file = True, mandatory = True),
        "readelf": attr.label(allow_single_file = True, mandatory = True),
        "runtime_libraries": attr.string_list(),
        "sysroot": attr.label(mandatory = True),
        "sysroot_marker": attr.label(allow_single_file = True, mandatory = True),
        "target_triplet": attr.string(mandatory = True),
        "_runtime_stager": attr.label(
            default = _RUNTIME_STAGER,
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Describes one checksum-pinned Linux libc target supported by rules_fips.",
)

fips_ubi_platform_toolchain = rule(
    implementation = _fips_ubi_platform_toolchain_impl,
    attrs = {
        "arch": attr.string(mandatory = True, values = ["amd64", "arm64"]),
        "clang_tools": attr.label(mandatory = True),
        "go": attr.label(mandatory = True),
        "libc_license_path": attr.string(mandatory = True),
        "loader": attr.string(mandatory = True),
        "loader_path": attr.string(mandatory = True),
        "nm": attr.label(allow_single_file = True, mandatory = True),
        "openssl_target": attr.string(mandatory = True),
        "qemu_aarch64": attr.label(allow_single_file = True),
        "ranlib": attr.label(allow_single_file = True, mandatory = True),
        "readelf": attr.label(allow_single_file = True, mandatory = True),
        "runtime_libraries": attr.string_dict(),
        "sysroot": attr.label(mandatory = True, providers = [UbiRpmTreeInfo]),
        "_runtime_stager": attr.label(
            default = _RUNTIME_STAGER,
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Describes a checksum-pinned UBI 10 target sysroot and runtime closure.",
)

fips_glibc_platform_toolchain = fips_bootlin_platform_toolchain
