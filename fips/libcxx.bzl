"""Static LLVM C++ runtimes layered onto a rules_fips musl sysroot."""

load("//fips:providers.bzl", "MuslSysrootInfo")
load(
    "//fips/private:tooling.bzl",
    "MAKE_TOOLCHAIN",
    "foreign_tool",
)

_BOOTSTRAP_TOOLCHAIN_TYPE = "//fips:bootstrap_toolchain_type"

def _static_libcxx_sysroot_impl(ctx):
    platform = ctx.toolchains[_BOOTSTRAP_TOOLCHAIN_TYPE].bootstrap
    make = foreign_tool(ctx, MAKE_TOOLCHAIN)
    musl = ctx.attr.musl[MuslSysrootInfo]
    sysroot = ctx.actions.declare_directory(ctx.label.name + "/sysroot")

    command = """
set -euo pipefail

source_root="$(dirname "$(dirname "$1")")"
musl_sysroot="$2"
sysroot_out="$3"
target_triplet="$4"
exec_root="${PWD}"
resolve_tool() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        */*) printf '%s/%s\n' "${exec_root}" "$1" ;;
        *) command -v "$1" ;;
    esac
}
cmake_bin="$(resolve_tool "$5")"
make_bin="$(resolve_tool "$6")"
cc_bin="$(resolve_tool "$7")"
cxx_bin="$(resolve_tool "$8")"
readelf_bin="$(resolve_tool "$9")"
source_root="$(resolve_tool "${source_root}")"
musl_sysroot="$(resolve_tool "${musl_sysroot}")"
sysroot_out="$(resolve_tool "${sysroot_out}")"

mkdir -p "${sysroot_out}"
cp -RL "${musl_sysroot}/." "${sysroot_out}/"
work="${sysroot_out}/.libcxx-build"
mkdir -p "${work}"
trap 'rm -rf "${work}"' EXIT
export TMPDIR="${work}/tmp"
mkdir -p "${TMPDIR}"

resource_dir="${sysroot_out}/usr/lib/clang/16"
target_flags="--target=${target_triplet} --sysroot=${sysroot_out} -resource-dir=${resource_dir}"
target_link_flags="${target_flags} --rtlib=compiler-rt -fuse-ld=lld -static"
"${cmake_bin}" -S "${source_root}/runtimes" -B "${work}/build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_ASM_COMPILER="${cc_bin}" \
    -DCMAKE_ASM_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_ASM_FLAGS="${target_flags}" \
    -DCMAKE_C_COMPILER="${cc_bin}" \
    -DCMAKE_C_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_C_FLAGS="${target_flags}" \
    -DCMAKE_CXX_COMPILER="${cxx_bin}" \
    -DCMAKE_CXX_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_CXX_FLAGS="${target_flags} -nostdinc++" \
    -DCMAKE_EXE_LINKER_FLAGS="${target_link_flags}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_MAKE_PROGRAM="${make_bin}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${target_link_flags}" \
    -DCMAKE_SYSROOT="${sysroot_out}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DLIBCXXABI_ENABLE_SHARED=OFF \
    -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
    -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=ON \
    -DLIBCXXABI_USE_COMPILER_RT=ON \
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXX_ENABLE_EXPERIMENTAL_LIBRARY=OFF \
    -DLIBCXX_ENABLE_SHARED=OFF \
    -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON \
    -DLIBCXX_HAS_MUSL_LIBC=ON \
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXX_INCLUDE_TESTS=OFF \
    -DLIBCXX_USE_COMPILER_RT=ON \
    -DLIBUNWIND_ENABLE_SHARED=OFF \
    -DLIBUNWIND_ENABLE_STATIC=ON \
    -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBUNWIND_USE_COMPILER_RT=ON \
    -DLLVM_DEFAULT_TARGET_TRIPLE="${target_triplet}" \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF
if ! "${cmake_bin}" --build "${work}/build" --parallel 8 \
    > "${work}/runtimes-build.log" 2>&1; then
    tail -200 "${work}/runtimes-build.log" >&2
    exit 1
fi
if ! DESTDIR="${sysroot_out}" "${cmake_bin}" --install "${work}/build" \
    > "${work}/runtimes-install.log" 2>&1; then
    tail -200 "${work}/runtimes-install.log" >&2
    exit 1
fi

test -f "${sysroot_out}/usr/include/c++/v1/__config"
test -f "${sysroot_out}/usr/lib/libc++.a"
test -f "${sysroot_out}/usr/lib/libc++abi.a"
test -f "${sysroot_out}/usr/lib/libunwind.a"
"${readelf_bin}" -h "${sysroot_out}/usr/lib/libc++.a" > "${work}/libcxx.headers"
"${readelf_bin}" -h "${sysroot_out}/usr/lib/libc++abi.a" > "${work}/libcxxabi.headers"
"${readelf_bin}" -h "${sysroot_out}/usr/lib/libunwind.a" > "${work}/libunwind.headers"
if [[ "${target_triplet}" = aarch64-* ]]; then
    grep -q 'Machine:.*AArch64' "${work}/libcxx.headers"
    grep -q 'Machine:.*AArch64' "${work}/libcxxabi.headers"
    grep -q 'Machine:.*AArch64' "${work}/libunwind.headers"
    ! grep -q 'Machine:.*X86-64' "${work}/libcxx.headers"
    ! grep -q 'Machine:.*X86-64' "${work}/libcxxabi.headers"
    ! grep -q 'Machine:.*X86-64' "${work}/libunwind.headers"
else
    grep -q 'Machine:.*X86-64' "${work}/libcxx.headers"
    grep -q 'Machine:.*X86-64' "${work}/libcxxabi.headers"
    grep -q 'Machine:.*X86-64' "${work}/libunwind.headers"
fi
mkdir -p \
    "${sysroot_out}/usr/share/licenses/libcxx" \
    "${sysroot_out}/usr/share/licenses/libcxxabi" \
    "${sysroot_out}/usr/share/licenses/libunwind"
cp "${source_root}/libcxx/LICENSE.TXT" \
    "${sysroot_out}/usr/share/licenses/libcxx/LICENSE.TXT"
cp "${source_root}/libcxxabi/LICENSE.TXT" \
    "${sysroot_out}/usr/share/licenses/libcxxabi/LICENSE.TXT"
cp "${source_root}/libunwind/LICENSE.TXT" \
    "${sysroot_out}/usr/share/licenses/libunwind/LICENSE.TXT"

printf '%s\n' '#include <string>' 'int main() { std::string s("musl"); return s.size() != 4; }' \
    > "${work}/static-cxx-smoke.cc"
"${cxx_bin}" \
    --target="${target_triplet}" \
    --sysroot="${sysroot_out}" \
    -resource-dir="${resource_dir}" \
    --rtlib=compiler-rt \
    -stdlib=libc++ \
    -fuse-ld=lld \
    -static \
    "${work}/static-cxx-smoke.cc" \
    -o "${work}/static-cxx-smoke"
if "${readelf_bin}" -l "${work}/static-cxx-smoke" | grep -q 'INTERP'; then
    echo "libc++ smoke binary unexpectedly contains an ELF interpreter" >&2
    exit 1
fi
if "${readelf_bin}" -d "${work}/static-cxx-smoke" 2>/dev/null | grep -q 'NEEDED'; then
    echo "libc++ smoke binary unexpectedly contains a dynamic dependency" >&2
    exit 1
fi
"${work}/static-cxx-smoke"
rm -rf "${work}"
trap - EXIT
"""

    ctx.actions.run_shell(
        arguments = [
            ctx.file.source_root_marker.path,
            musl.sysroot.path,
            sysroot.path,
            musl.target_triplet,
            platform.cmake_bin,
            make.path,
            platform.clang_cc,
            platform.clang_cxx,
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
            direct = [ctx.file.source_root_marker],
            transitive = [
                ctx.attr.source[DefaultInfo].files,
                ctx.attr.musl[DefaultInfo].files,
                make.inputs,
                platform.clang_files,
                platform.cmake_files,
            ],
        ),
        mnemonic = "StaticLibcxxSysrootBuild",
        outputs = [sysroot],
        progress_message = "Building static LLVM 16 C++ runtimes for %s" % platform.arch,
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([sysroot])),
        MuslSysrootInfo(
            compiler_rt = sysroot.path + "/usr/lib/libclang_rt.builtins.a",
            compiler_rt_license = sysroot.path + "/usr/share/licenses/compiler-rt/LICENSE.TXT",
            license = musl.license,
            revision = musl.revision,
            sysroot = sysroot,
            target_triplet = musl.target_triplet,
        ),
    ]

static_libcxx_sysroot = rule(
    implementation = _static_libcxx_sysroot_impl,
    attrs = {
        "musl": attr.label(
            mandatory = True,
            providers = [MuslSysrootInfo],
        ),
        "source": attr.label(default = "@llvm_project_src//:runtimes_srcs"),
        "source_root_marker": attr.label(
            allow_single_file = True,
            default = "@llvm_project_src//:llvm/CMakeLists.txt",
        ),
    },
    doc = "Builds matching static LLVM 16 C++ runtimes into a musl sysroot.",
    toolchains = [_BOOTSTRAP_TOOLCHAIN_TYPE, MAKE_TOOLCHAIN],
)
