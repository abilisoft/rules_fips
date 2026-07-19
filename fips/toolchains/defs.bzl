"""Architecture toolchains used by rules_fips build actions."""

load(
    "//fips:providers.bzl",
    "FipsPlatformInfo",
    "MuslSysrootInfo",
)

def _single_tree(target, description):
    roots = target[DefaultInfo].files.to_list()
    if len(roots) != 1:
        fail("%s must expose exactly one source directory" % description)
    return roots[0], target[DefaultInfo].files

def _clang_values(ctx):
    return struct(
        cc = ctx.file.clang,
        cxx = ctx.file.clangxx,
        files = ctx.attr.clang_tools[DefaultInfo].files,
        llvm_ar = ctx.file.ar.path,
        llvm_ld = ctx.file.ld.path,
        llvm_nm = ctx.file.nm.path,
        llvm_objcopy = ctx.file.objcopy.path,
        llvm_objdump = ctx.file.objdump.path,
        llvm_ranlib = ctx.file.ranlib.path,
        llvm_readelf = ctx.file.readelf.path,
        llvm_strip = ctx.file.strip.path,
    )

def _archive_tool(target, description, suffix):
    root, files = _single_tree(target, description)
    return root.path + suffix, files

def _musl_source_root(marker):
    suffix = "/COPYRIGHT"
    if not marker.path.endswith(suffix):
        fail("musl source marker must end with %s" % suffix)
    return marker.path.removesuffix(suffix)

def _build_musl_crt(ctx, clang, musl):
    source_root = _musl_source_root(ctx.file.musl_source_marker)
    musl_arch = "x86_64" if ctx.attr.arch == "amd64" else "aarch64"
    source_by_output = {
        "Scrt1.o": "crt/Scrt1.c",
        "crt1.o": "crt/crt1.c",
        "crti.o": "crt/%s/crti.s" % musl_arch,
        "crtn.o": "crt/%s/crtn.s" % musl_arch,
        "rcrt1.o": "crt/rcrt1.c",
    }
    outputs = []
    for output_name, source_path in source_by_output.items():
        output = ctx.actions.declare_file(ctx.label.name + "_crt/" + output_name)
        ctx.actions.run(
            arguments = [
                "--target=" + musl.target_triplet,
                "--sysroot=" + musl.sysroot_path,
                "-resource-dir=" + musl.resource_dir,
                "-I" + source_root + "/arch/" + musl_arch,
                "-I" + source_root + "/arch/generic",
                "-I" + source_root + "/src/include",
                "-I" + source_root + "/include",
                "-I" + source_root + "/src/internal",
                "-fPIC",
                "-c",
                source_root + "/" + source_path,
                "-o",
                output.path,
            ],
            env = {
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "SOURCE_DATE_EPOCH": "0",
            },
            executable = clang.cc,
            execution_requirements = {"block-network": "1"},
            inputs = depset(
                transitive = [
                    clang.files,
                    musl.files,
                    ctx.attr.musl_source[DefaultInfo].files,
                ],
            ),
            mnemonic = "MuslCrtCompile",
            outputs = [output],
            progress_message = "Compiling musl CRT %s for %s" % (output_name, ctx.attr.arch),
        )
        outputs.append(output)
    return outputs

def _fips_platform_toolchain_impl(ctx):
    clang = _clang_values(ctx)
    go_bin, go_files = _archive_tool(
        ctx.attr.go,
        "pinned Go archive",
        "/bin/go",
    )
    musl = ctx.attr.musl[MuslSysrootInfo]
    crt_files = _build_musl_crt(ctx, clang, musl)
    info = FipsPlatformInfo(
        arch = ctx.attr.arch,
        clang_files = clang.files,
        clang_library_path = "",
        clang_resource_dir = musl.resource_dir,
        clang_runtime_files = clang.files,
        compiler_rt_license_path = musl.compiler_rt_license,
        compiler_rt_path = musl.compiler_rt,
        crt_dir = crt_files[0].dirname,
        crt_files = depset(crt_files),
        go_bin = go_bin,
        go_files = go_files,
        libc = "musl",
        llvm_ar = clang.llvm_ar,
        llvm_ld = clang.llvm_ld,
        llvm_nm = clang.llvm_nm,
        llvm_objcopy = clang.llvm_objcopy,
        llvm_objdump = clang.llvm_objdump,
        llvm_ranlib = clang.llvm_ranlib,
        llvm_readelf = clang.llvm_readelf,
        llvm_strip = clang.llvm_strip,
        musl_revision = musl.revision,
        musl_libc_file = musl.libc,
        musl_license_file = musl.license,
        musl_loader_file = musl.loader,
        musl_loader_path = musl.loader.path,
        musl_triplet = musl.target_triplet,
        openssl_target = ctx.attr.openssl_target,
        qemu_aarch64_file = ctx.file.qemu_aarch64,
        qemu_aarch64_files = ctx.attr.qemu_aarch64[DefaultInfo].files,
        resource_dir = musl.resource_dir,
        sysroot_files = musl.files,
        sysroot_path = musl.sysroot_path,
    )
    return [
        info,
        platform_common.ToolchainInfo(fips = info),
    ]

fips_platform_toolchain = rule(
    implementation = _fips_platform_toolchain_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "ar": attr.label(allow_single_file = True, mandatory = True),
        "clang": attr.label(allow_single_file = True, mandatory = True),
        "clang_tools": attr.label(mandatory = True),
        "clangxx": attr.label(allow_single_file = True, mandatory = True),
        "go": attr.label(mandatory = True),
        "musl": attr.label(
            mandatory = True,
            providers = [MuslSysrootInfo],
        ),
        "musl_source": attr.label(mandatory = True),
        "musl_source_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "ld": attr.label(allow_single_file = True, mandatory = True),
        "nm": attr.label(allow_single_file = True, mandatory = True),
        "objcopy": attr.label(allow_single_file = True, mandatory = True),
        "objdump": attr.label(allow_single_file = True, mandatory = True),
        "openssl_target": attr.string(mandatory = True),
        "qemu_aarch64": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "ranlib": attr.label(allow_single_file = True, mandatory = True),
        "readelf": attr.label(allow_single_file = True, mandatory = True),
        "strip": attr.label(allow_single_file = True, mandatory = True),
    },
    doc = "Describes one self-contained musl Linux target supported by rules_fips.",
)
