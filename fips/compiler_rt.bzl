"""Pinned Clang runtime builtins used to bootstrap musl and static OTP links."""

load(
    "//fips/private:tooling.bzl",
    "MAKE_TOOLCHAIN",
    "foreign_tool",
)

_BOOTSTRAP_TOOLCHAIN_TYPE = "//fips:bootstrap_toolchain_type"

CompilerRtBuiltinsInfo = provider(
    doc = "The architecture-specific compiler-rt builtins archive and license.",
    fields = {
        "archive": "Static compiler runtime builtins archive.",
        "crtbegin": "Compiler-rt constructor registration start object.",
        "crtend": "Compiler-rt constructor registration end object.",
        "license": "LLVM compiler-rt license file.",
    },
)

def _single_directory(target, description):
    files = target[DefaultInfo].files.to_list()
    if len(files) != 1:
        fail("%s must expose exactly one source directory" % description)
    return files[0]

def _compiler_rt_builtins_impl(ctx):
    platform = ctx.toolchains[_BOOTSTRAP_TOOLCHAIN_TYPE].bootstrap
    make = foreign_tool(ctx, MAKE_TOOLCHAIN)
    llvm_cmake = _single_directory(ctx.attr.llvm_cmake, "LLVM CMake source")
    archive = ctx.actions.declare_file(ctx.label.name + "/lib/libclang_rt.builtins.a")
    crtbegin = ctx.actions.declare_file(ctx.label.name + "/lib/crtbegin.o")
    crtend = ctx.actions.declare_file(ctx.label.name + "/lib/crtend.o")
    license_file = ctx.actions.declare_file(ctx.label.name + "/licenses/compiler-rt.txt")
    scratch = ctx.actions.declare_directory(ctx.label.name + ".scratch")

    command = """
set -euo pipefail

source_root="$(dirname "$1")"
llvm_root="$2"
llvm_common_marker="$3"
archive_out="$4"
crtbegin_out="$5"
crtend_out="$6"
license_out="$7"
scratch="$8"
target_triplet="$9"
exec_root="${PWD}"
resolve_tool() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        */*) printf '%s/%s\n' "${exec_root}" "$1" ;;
        *) command -v "$1" ;;
    esac
}
cmake_bin="$(resolve_tool "${10}")"
make_bin="$(resolve_tool "${11}")"
cc_bin="$(resolve_tool "${12}")"
bootstrap_sysroot="$(resolve_tool "${13}")"
readelf_bin="$(resolve_tool "${14}")"
llvm_root="$(resolve_tool "${llvm_root}")"
llvm_common_marker="$(resolve_tool "${llvm_common_marker}")"
llvm_common_root="$(dirname "$(dirname "${llvm_common_marker}")")"
scratch="$(resolve_tool "${scratch}")"

mkdir -p "${scratch}"
work="${scratch}/work"
mkdir -p "${work}"
trap 'rm -rf "${work}"' EXIT
export TMPDIR="${work}/tmp"
mkdir -p "${TMPDIR}"

"${cmake_bin}" -S "${source_root}/lib/builtins" -B "${work}/build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${cc_bin}" \
    -DCMAKE_C_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_C_FLAGS="--target=${target_triplet} --sysroot=${bootstrap_sysroot}" \
    -DCMAKE_ASM_COMPILER="${cc_bin}" \
    -DCMAKE_ASM_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_ASM_FLAGS="--target=${target_triplet} --sysroot=${bootstrap_sysroot}" \
    -DCMAKE_MAKE_PROGRAM="${make_bin}" \
    -DCMAKE_MODULE_PATH="${llvm_common_root}/Modules;${llvm_root}/cmake/modules" \
    -DCMAKE_SYSROOT="${bootstrap_sysroot}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DLLVM_MAIN_SRC_DIR="${llvm_root}"
"${cmake_bin}" --build "${work}/build" --parallel 8

"${cmake_bin}" -S "${source_root}/lib/crt" -B "${work}/crt-build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${cc_bin}" \
    -DCMAKE_C_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_C_FLAGS="--target=${target_triplet} --sysroot=${bootstrap_sysroot}" \
    -DCMAKE_ASM_COMPILER="${cc_bin}" \
    -DCMAKE_ASM_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_ASM_FLAGS="--target=${target_triplet} --sysroot=${bootstrap_sysroot}" \
    -DCMAKE_MAKE_PROGRAM="${make_bin}" \
    -DCMAKE_MODULE_PATH="${llvm_common_root}/Modules;${llvm_root}/cmake/modules" \
    -DCMAKE_SYSROOT="${bootstrap_sysroot}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCOMPILER_RT_CRT_USE_EH_FRAME_REGISTRY=OFF \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DLLVM_MAIN_SRC_DIR="${llvm_root}"
mkdir -p "${work}/crt-build/lib/linux"
"${cmake_bin}" --build "${work}/crt-build" --parallel 8

builtins="$(find "${work}/build" -type f -name 'libclang_rt.builtins*.a' -print -quit)"
crtbegin_built="$(find "${work}/crt-build" -type f -name 'clang_rt.crtbegin*.o' -print -quit)"
crtend_built="$(find "${work}/crt-build" -type f -name 'clang_rt.crtend*.o' -print -quit)"
test -n "${builtins}"
test -n "${crtbegin_built}"
test -n "${crtend_built}"
mkdir -p "$(dirname "${archive_out}")" "$(dirname "${license_out}")"
cp "${builtins}" "${archive_out}"
cp "${crtbegin_built}" "${crtbegin_out}"
cp "${crtend_built}" "${crtend_out}"
cp "${source_root}/LICENSE.TXT" "${license_out}"
"${readelf_bin}" -h "${archive_out}" > "${work}/archive.headers"
"${readelf_bin}" -h "${crtbegin_out}" > "${work}/crtbegin.headers"
"${readelf_bin}" -h "${crtend_out}" > "${work}/crtend.headers"
if [[ "${target_triplet}" = aarch64-* ]]; then
    grep -q 'Machine:.*AArch64' "${work}/archive.headers"
    ! grep -q 'Machine:.*X86-64' "${work}/archive.headers"
    grep -q 'Machine:.*AArch64' "${work}/crtbegin.headers"
    grep -q 'Machine:.*AArch64' "${work}/crtend.headers"
else
    grep -q 'Machine:.*X86-64' "${work}/archive.headers"
    ! grep -q 'Machine:.*AArch64' "${work}/archive.headers"
fi
rm -rf "${work}"
trap - EXIT
"""

    ctx.actions.run_shell(
        arguments = [
            ctx.file.source_root_marker.path,
            llvm_cmake.path,
            ctx.file.llvm_common_marker.path,
            archive.path,
            crtbegin.path,
            crtend.path,
            license_file.path,
            scratch.path,
            platform.musl_triplet,
            platform.cmake_bin,
            make.path,
            platform.clang_cc,
            platform.glibc_sysroot_path,
            platform.llvm_readelf,
        ],
        command = command,
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "SOURCE_DATE_EPOCH": "0",
        },
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [ctx.file.source_root_marker, ctx.file.llvm_common_marker, llvm_cmake],
            transitive = [
                ctx.attr.source[DefaultInfo].files,
                ctx.attr.llvm_common_cmake[DefaultInfo].files,
                make.inputs,
                platform.clang_files,
                platform.cmake_files,
                platform.glibc_sysroot_files,
            ],
        ),
        mnemonic = "CompilerRtBuiltinsBuild",
        outputs = [archive, crtbegin, crtend, license_file, scratch],
        progress_message = "Building Clang 16 compiler-rt builtins for %s" % platform.arch,
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([archive, crtbegin, crtend, license_file])),
        CompilerRtBuiltinsInfo(
            archive = archive,
            crtbegin = crtbegin,
            crtend = crtend,
            license = license_file,
        ),
    ]

compiler_rt_builtins = rule(
    implementation = _compiler_rt_builtins_impl,
    attrs = {
        "llvm_cmake": attr.label(default = "@fips_llvm_cmake//sysroot:sysroot"),
        "llvm_common_cmake": attr.label(default = "@llvm_common_cmake_src//:srcs"),
        "llvm_common_marker": attr.label(
            allow_single_file = True,
            default = "@llvm_common_cmake_src//:Modules/ExtendPath.cmake",
        ),
        "source": attr.label(default = "@compiler_rt_src//:srcs"),
        "source_root_marker": attr.label(
            allow_single_file = True,
            default = "@compiler_rt_src//:CMakeLists.txt",
        ),
    },
    doc = "Builds Clang 16.0.0 compiler runtime builtins for the selected platform.",
    toolchains = [_BOOTSTRAP_TOOLCHAIN_TYPE, MAKE_TOOLCHAIN],
)
