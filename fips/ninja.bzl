"""Builds the exact Ninja release named by the BoringCrypto security policy."""

load("//fips:providers.bzl", "PolicyNinjaInfo")
load(
    "//fips/private:tooling.bzl",
    "MAKE_TOOLCHAIN",
    "foreign_tool",
)

_TOOLCHAIN_TYPE = "//fips:toolchain_type"

def _policy_ninja_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    make = foreign_tool(ctx, MAKE_TOOLCHAIN)
    binary = ctx.actions.declare_file(ctx.label.name + "/bin/ninja")
    license_file = ctx.actions.declare_file(ctx.label.name + "/licenses/ninja.txt")

    command = """
set -euo pipefail

source_root="$(dirname "$1")"
binary_out="$2"
license_out="$3"
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
binary_out="$(resolve_tool "${binary_out}")"
license_out="$(resolve_tool "${license_out}")"
sysroot="$(resolve_tool "${10}")"

work="$(dirname "${binary_out}")/.build-work"
mkdir -p "${work}" "$(dirname "${binary_out}")" "$(dirname "${license_out}")"
trap 'rm -rf "${work}"' EXIT
export TMPDIR="${work}/tmp"
mkdir -p "${TMPDIR}"
resource_dir="${sysroot}/usr/lib/clang/16"
target_flags="--sysroot=${sysroot} -resource-dir=${resource_dir}"
link_flags="${target_flags} --rtlib=compiler-rt -fuse-ld=lld -static"

"${cmake_bin}" -S "${source_root}" -B "${work}/build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${cc_bin}" \
    -DCMAKE_C_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_C_FLAGS="${target_flags}" \
    -DCMAKE_CXX_COMPILER="${cxx_bin}" \
    -DCMAKE_CXX_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_CXX_FLAGS="${target_flags} -stdlib=libc++" \
    -DCMAKE_EXE_LINKER_FLAGS="${link_flags}" \
    -DCMAKE_MAKE_PROGRAM="${make_bin}" \
    -DCMAKE_SYSROOT="${sysroot}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DBUILD_TESTING=OFF
"${cmake_bin}" --build "${work}/build" --parallel 8
cp "${work}/build/ninja" "${binary_out}"
cp "${source_root}/COPYING" "${license_out}"

test "$("${binary_out}" --version)" = "1.11.1"
if "${readelf_bin}" -l "${binary_out}" | grep -q 'INTERP'; then
    echo "policy Ninja unexpectedly contains an ELF interpreter" >&2
    exit 1
fi
if "${readelf_bin}" -d "${binary_out}" 2>/dev/null | grep -q 'NEEDED'; then
    echo "policy Ninja unexpectedly contains a dynamic dependency" >&2
    exit 1
fi
rm -rf "${work}"
trap - EXIT
"""

    ctx.actions.run_shell(
        arguments = [
            ctx.file.source_root_marker.path,
            binary.path,
            license_file.path,
            platform.musl_triplet,
            platform.cmake_bin,
            make.path,
            platform.clang_cc,
            platform.clang_cxx,
            platform.llvm_readelf,
            platform.sysroot_path,
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
                make.inputs,
                platform.clang_files,
                platform.cmake_files,
                platform.sysroot_files,
            ],
        ),
        mnemonic = "PolicyNinjaBuild",
        outputs = [binary, license_file],
        progress_message = "Building static Ninja 1.11.1 for %s" % platform.arch,
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([binary, license_file])),
        PolicyNinjaInfo(
            binary = binary,
            files = depset([binary, license_file]),
            version = "1.11.1",
        ),
    ]

policy_ninja = rule(
    implementation = _policy_ninja_impl,
    attrs = {
        "source": attr.label(default = "@ninja_1_11_1_src//:srcs"),
        "source_root_marker": attr.label(
            allow_single_file = True,
            default = "@ninja_1_11_1_src//:CMakeLists.txt",
        ),
    },
    doc = "Builds a fully static Ninja 1.11.1 executable with the target musl toolchain.",
    toolchains = [_TOOLCHAIN_TYPE, MAKE_TOOLCHAIN],
)
