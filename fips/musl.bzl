"""Hermetic, source-built musl sysroots for fully static target artifacts."""

load("//fips:compiler_rt.bzl", "CompilerRtBuiltinsInfo")
load("//fips:providers.bzl", "MuslSysrootInfo")
load(
    "//fips/private:tooling.bzl",
    "MAKE_TOOLCHAIN",
    "foreign_tool",
)

_BOOTSTRAP_TOOLCHAIN_TYPE = "//fips:bootstrap_toolchain_type"

def _musl_sysroot_impl(ctx):
    platform = ctx.toolchains[_BOOTSTRAP_TOOLCHAIN_TYPE].bootstrap
    make = foreign_tool(ctx, MAKE_TOOLCHAIN)
    sysroot = ctx.actions.declare_directory(ctx.label.name + "/sysroot")
    license_file = ctx.actions.declare_file(ctx.label.name + "/licenses/musl.txt")

    command = """
set -euo pipefail

source_root="$(dirname "$1")"
linux_source_root="$(dirname "$2")"
sysroot_out="$3"
license_out="$4"
revision="$5"
musl_triplet="$6"
build_triplet="$7"
kernel_arch="$8"
exec_root="${PWD}"
resolve_tool() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        */*) printf '%s/%s\n' "${exec_root}" "$1" ;;
        *) command -v "$1" ;;
    esac
}
make_bin="$(resolve_tool "$9")"
cc_bin="$(resolve_tool "${10}")"
ar_bin="$(resolve_tool "${11}")"
ranlib_bin="$(resolve_tool "${12}")"
builtins="$(resolve_tool "${13}")"
crtbegin="$(resolve_tool "${14}")"
crtend="$(resolve_tool "${15}")"
builtins_license="$(resolve_tool "${16}")"
readelf_bin="$(resolve_tool "${17}")"
linux_source_root="$(resolve_tool "${linux_source_root}")"
sysroot_out="$(resolve_tool "${sysroot_out}")"
license_out="$(resolve_tool "${license_out}")"

mkdir -p "${sysroot_out}"
work="${sysroot_out}/.build-work"
mkdir -p "${work}"
trap 'rm -rf "${work}"' EXIT
cp -RL "${source_root}" "${work}/src"
mkdir -p "${work}/build"

"${make_bin}" \
    -C "${linux_source_root}" \
    O="${work}/linux-build" \
    ARCH="${kernel_arch}" \
    INSTALL_HDR_PATH="${sysroot_out}/usr" \
    headers_install
test -f "${sysroot_out}/usr/include/linux/futex.h"

(
    cd "${work}/build"
    CC="${cc_bin} --target=${musl_triplet} -fuse-ld=lld" \
    AR="${ar_bin}" \
    RANLIB="${ranlib_bin}" \
    LIBCC="${builtins}" \
    CFLAGS="-O2" \
    LDFLAGS="-fuse-ld=lld" \
        "${work}/src/configure" \
            --prefix=/usr \
            --syslibdir=/lib \
            --build="${build_triplet}" \
            --target="${musl_triplet}" \
            --disable-shared \
            --enable-static \
            --enable-wrapper=no
    "${make_bin}" -j8
    "${make_bin}" DESTDIR="${sysroot_out}" install
)

test -f "${sysroot_out}/usr/include/stdio.h"
test -f "${sysroot_out}/usr/lib/libc.a"
test -f "${sysroot_out}/usr/lib/crt1.o"
test ! -e "${sysroot_out}/lib/ld-musl-${musl_triplet%%-*}.so.1"

clang_root="$(dirname "$(dirname "${cc_bin}")")"
resource_dir="${sysroot_out}/usr/lib/clang/16"
mkdir -p "${resource_dir}/include" "${resource_dir}/lib/linux"
cp -R "${clang_root}/lib/clang/16/include/." "${resource_dir}/include/"
cp "${builtins}" \
    "${resource_dir}/lib/linux/libclang_rt.builtins-${musl_triplet%%-*}.a"
cp "${builtins}" "${sysroot_out}/usr/lib/libclang_rt.builtins.a"
cp "${crtbegin}" "${sysroot_out}/usr/lib/crtbegin.o"
cp "${crtbegin}" "${sysroot_out}/usr/lib/crtbeginS.o"
cp "${crtbegin}" "${sysroot_out}/usr/lib/crtbeginT.o"
cp "${crtend}" "${sysroot_out}/usr/lib/crtend.o"
cp "${crtend}" "${sysroot_out}/usr/lib/crtendS.o"

printf '%s\n' 'int main(void) { return 0; }' > "${work}/static-smoke.c"
"${cc_bin}" \
    --target="${musl_triplet}" \
    --sysroot="${sysroot_out}" \
    -resource-dir="${resource_dir}" \
    --rtlib=compiler-rt \
    -fuse-ld=lld \
    -static \
    "${work}/static-smoke.c" \
    -o "${work}/static-smoke"
if "${readelf_bin}" -l "${work}/static-smoke" | grep -q 'INTERP'; then
    echo "musl smoke binary unexpectedly contains an ELF interpreter" >&2
    exit 1
fi
if "${readelf_bin}" -d "${work}/static-smoke" 2>/dev/null | grep -q 'NEEDED'; then
    echo "musl smoke binary unexpectedly contains a dynamic dependency" >&2
    exit 1
fi
"${work}/static-smoke"

mkdir -p "$(dirname "${license_out}")" "${sysroot_out}/usr/share/licenses/musl"
cp "${work}/src/COPYRIGHT" "${license_out}"
cp "${work}/src/COPYRIGHT" "${sysroot_out}/usr/share/licenses/musl/COPYRIGHT"
mkdir -p \
    "${sysroot_out}/usr/share/licenses/compiler-rt" \
    "${sysroot_out}/usr/share/licenses/linux-headers/LICENSES"
cp "${builtins_license}" \
    "${sysroot_out}/usr/share/licenses/compiler-rt/LICENSE.TXT"
cp "${linux_source_root}/COPYING" \
    "${sysroot_out}/usr/share/licenses/linux-headers/COPYING"
cp -R "${linux_source_root}/LICENSES/." \
    "${sysroot_out}/usr/share/licenses/linux-headers/LICENSES/"
printf '%s\n' "${revision}" > "${sysroot_out}/MUSL_REVISION"
rm -rf "${work}"
trap - EXIT
"""

    ctx.actions.run_shell(
        arguments = [
            ctx.file.source_root_marker.path,
            ctx.file.linux_headers_root_marker.path,
            sysroot.path,
            license_file.path,
            ctx.attr.revision,
            platform.musl_triplet,
            platform.gnu_triplet,
            "x86" if platform.arch == "amd64" else "arm64",
            make.path,
            platform.clang_cc,
            platform.llvm_ar,
            platform.llvm_ranlib,
            ctx.attr.compiler_rt[CompilerRtBuiltinsInfo].archive.path,
            ctx.attr.compiler_rt[CompilerRtBuiltinsInfo].crtbegin.path,
            ctx.attr.compiler_rt[CompilerRtBuiltinsInfo].crtend.path,
            ctx.attr.compiler_rt[CompilerRtBuiltinsInfo].license.path,
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
            direct = [
                ctx.file.linux_headers_root_marker,
                ctx.file.source_root_marker,
            ],
            transitive = [
                ctx.attr.source[DefaultInfo].files,
                ctx.attr.linux_headers[DefaultInfo].files,
                ctx.attr.compiler_rt[DefaultInfo].files,
                make.inputs,
                platform.clang_files,
                platform.glibc_sysroot_files,
            ],
        ),
        mnemonic = "MuslSysrootBuild",
        outputs = [sysroot, license_file],
        progress_message = "Building static musl sysroot for %s" % platform.arch,
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([sysroot, license_file])),
        MuslSysrootInfo(
            compiler_rt = sysroot.path + "/usr/lib/libclang_rt.builtins.a",
            compiler_rt_license = sysroot.path + "/usr/share/licenses/compiler-rt/LICENSE.TXT",
            license = license_file,
            revision = ctx.attr.revision,
            sysroot = sysroot,
            target_triplet = platform.musl_triplet,
        ),
    ]

musl_sysroot = rule(
    implementation = _musl_sysroot_impl,
    attrs = {
        "compiler_rt": attr.label(
            mandatory = True,
            providers = [CompilerRtBuiltinsInfo],
        ),
        "linux_headers": attr.label(default = "@linux_headers_src//:srcs"),
        "linux_headers_root_marker": attr.label(
            allow_single_file = True,
            default = "@linux_headers_src//:Makefile",
        ),
        "revision": attr.string(
            default = "b306b16af15c89a04d8e0c55cac2dadbeb39c083",
        ),
        "source": attr.label(default = "@musl_src//:srcs"),
        "source_root_marker": attr.label(
            allow_single_file = True,
            default = "@musl_src//:configure",
        ),
    },
    doc = "Builds a static-only musl sysroot from a pinned upstream revision.",
    toolchains = [_BOOTSTRAP_TOOLCHAIN_TYPE, MAKE_TOOLCHAIN],
)
