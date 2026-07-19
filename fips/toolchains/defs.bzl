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
        llvm_ld = root.path + "/bin/ld.lld",
        llvm_nm = root.path + "/bin/llvm-nm",
        llvm_objcopy = root.path + "/bin/llvm-objcopy",
        llvm_objdump = root.path + "/bin/llvm-objdump",
        llvm_ranlib = root.path + "/bin/llvm-ranlib",
        llvm_readelf = root.path + "/bin/llvm-readelf",
        llvm_strip = root.path + "/bin/llvm-strip",
        resource_dir = root.path + "/lib/clang/22",
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

def _clang_runtime(ctx, triplet):
    icu_root, icu_files = _single_tree(ctx.attr.clang_libicu, "pinned LLVM ICU runtime")
    libxml_root, libxml_files = _single_tree(ctx.attr.clang_libxml2, "pinned LLVM libxml2 runtime")
    return struct(
        files = depset(transitive = [icu_files, libxml_files]),
        path = ":".join([
            libxml_root.path + "/usr/lib/" + triplet,
            icu_root.path + "/usr/lib/" + triplet,
        ]),
    )

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
    clang_runtime = _clang_runtime(ctx, ctx.attr.build_triplet)
    build_musl = ctx.attr.build_musl[MuslSysrootInfo]
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
    crt_files = _build_musl_crt(ctx, clang, musl)
    info = FipsPlatformInfo(
        arch = ctx.attr.arch,
        boringssl_processor = ctx.attr.boringssl_processor,
        build_compiler_rt_files = build_musl.files,
        build_compiler_rt_path = build_musl.compiler_rt,
        build_sysroot_files = ctx.attr.build_glibc_sysroot[DefaultInfo].files,
        build_sysroot_path = _sysroot_from_marker(ctx.file.build_glibc_sysroot_marker),
        build_triplet = ctx.attr.build_triplet,
        clang_cc = clang.cc,
        clang_cxx = clang.cxx,
        clang_files = clang.files,
        clang_library_path = clang_runtime.path,
        clang_resource_dir = clang.resource_dir,
        clang_runtime_files = clang_runtime.files,
        cmake_bin = cmake_bin,
        cmake_files = cmake_files,
        compiler_rt_license_path = musl.compiler_rt_license,
        compiler_rt_path = musl.compiler_rt,
        crt_dir = crt_files[0].dirname,
        crt_files = depset(crt_files),
        go_bin = go_bin,
        go_files = go_files,
        gnu_triplet = ctx.attr.gnu_triplet,
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
        "boringssl_processor": attr.string(mandatory = True),
        "build_musl": attr.label(
            mandatory = True,
            providers = [MuslSysrootInfo],
        ),
        "build_glibc_sysroot": attr.label(mandatory = True),
        "build_glibc_sysroot_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "build_triplet": attr.string(mandatory = True),
        "clang": attr.label(mandatory = True),
        "clang_libicu": attr.label(mandatory = True),
        "clang_libxml2": attr.label(mandatory = True),
        "cmake": attr.label(mandatory = True),
        "go": attr.label(mandatory = True),
        "gnu_triplet": attr.string(mandatory = True),
        "musl": attr.label(
            mandatory = True,
            providers = [MuslSysrootInfo],
        ),
        "musl_source": attr.label(mandatory = True),
        "musl_source_marker": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "openssl_target": attr.string(mandatory = True),
    },
    doc = "Describes one fully static musl Linux target supported by rules_fips.",
)
