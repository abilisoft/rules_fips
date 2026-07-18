"""Rules that build validated cryptographic modules from pinned source trees."""

load("//fips:providers.bzl", "FipsCryptoInfo", "PolicyNinjaInfo")
load(
    "//fips/private:tooling.bzl",
    "MAKE_TOOLCHAIN",
    "foreign_tool",
)

_TOOLCHAIN_TYPE = "//fips:toolchain_type"

def _all_inputs(targets, files = [], transitive = []):
    return depset(
        direct = files,
        transitive = [target[DefaultInfo].files for target in targets] + transitive,
    )

def _compile_flags(platform):
    return "--sysroot=" + platform.sysroot_path

def _link_flags(platform):
    return " ".join([
        _compile_flags(platform),
        "-fuse-ld=lld",
        "-Wl,-S",
        "-Wl,-z,relro,-z,now",
    ])

def _boringcrypto_fips_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    ninja = ctx.attr.ninja[PolicyNinjaInfo]
    libcrypto = ctx.actions.declare_file(ctx.label.name + "/lib/libcrypto.a")
    libssl = ctx.actions.declare_file(ctx.label.name + "/lib/libssl.a")
    include_dir = ctx.actions.declare_directory(ctx.label.name + "/include")
    checker = ctx.actions.declare_file(ctx.label.name + "/bin/boring-fips-check")
    license_file = ctx.actions.declare_file(ctx.label.name + "/licenses/boringssl.txt")
    manifest = ctx.actions.declare_file(ctx.label.name + "/FIPS_BUILD.json")

    command = """
set -euo pipefail

source_root="$(dirname "$1")"
exec_root="${PWD}"
resolve_tool() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        */*) printf '%s/%s\n' "${exec_root}" "$1" ;;
        *) command -v "$1" ;;
    esac
}
checker_source="$2"
libcrypto_out="$3"
libssl_out="$4"
include_out="$5"
checker_out="$6"
license_out="$7"
manifest_out="$8"
arch="$9"
processor="${10}"
cmake_bin="$(resolve_tool "${11}")"
ninja_bin="$(resolve_tool "${12}")"
go_bin="$(resolve_tool "${13}")"
cc_bin="$(resolve_tool "${14}")"
cxx_bin="$(resolve_tool "${15}")"
ar_bin="$(resolve_tool "${16}")"
ranlib_bin="$(resolve_tool "${17}")"
readelf_bin="$(resolve_tool "${18}")"
target_triplet="${19}"
sysroot="$(resolve_tool "${20}")"
musl_revision="${21}"

mkdir -p "${include_out}"
work="${exec_root}/${include_out}/.build-work"
mkdir -p "${work}"
trap 'rm -rf "${work}"' EXIT
export GOCACHE="${work}/gocache"
export GOENV=off
export GONOSUMDB='*'
export GOPROXY=off
export GOROOT="$(dirname "$(dirname "${go_bin}")")"
export GOSUMDB=off
export GOTOOLCHAIN=local
export HOME="${work}/home"
export PATH="$(dirname "${go_bin}"):/usr/bin:/bin"
export TMPDIR="${work}/tmp"
mkdir -p "${GOCACHE}" "${HOME}" "${TMPDIR}"
cp -RL "${source_root}" "${work}/src"

"${cmake_bin}" --version | head -1 | grep -Fx 'cmake version 3.27.4'
"${go_bin}" version | grep -F 'go version go1.21.1 '
test "$("${ninja_bin}" --version)" = 1.11.1
resource_dir="${sysroot}/usr/lib/clang/16"
target_flags="--target=${target_triplet} --sysroot=${sysroot} -resource-dir=${resource_dir} -O2 -fPIC"
target_link_flags="--target=${target_triplet} --sysroot=${sysroot} -resource-dir=${resource_dir} --rtlib=compiler-rt -fuse-ld=lld -static"

"${cmake_bin}" -S "${work}/src" -B "${work}/build" -GNinja \
    -DFIPS=1 \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_AR="${ar_bin}" \
    -DCMAKE_ASM_COMPILER="${cc_bin}" \
    -DCMAKE_ASM_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_ASM_FLAGS="${target_flags}" \
    -DCMAKE_C_COMPILER="${cc_bin}" \
    -DCMAKE_C_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_CXX_COMPILER="${cxx_bin}" \
    -DCMAKE_CXX_COMPILER_TARGET="${target_triplet}" \
    -DCMAKE_C_FLAGS="${target_flags}" \
    -DCMAKE_CXX_FLAGS="${target_flags} -stdlib=libc++" \
    -DCMAKE_EXE_LINKER_FLAGS="${target_link_flags} -stdlib=libc++" \
    -DCMAKE_MAKE_PROGRAM="${ninja_bin}" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_RANLIB="${ranlib_bin}" \
    -DCMAKE_SHARED_LINKER_FLAGS="${target_link_flags} -stdlib=libc++" \
    -DCMAKE_SYSROOT="${sysroot}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR="${processor}" \
    -DGO_EXECUTABLE="${go_bin}"
"${cmake_bin}" --build "${work}/build" --target crypto ssl

mkdir -p \
    "$(dirname "${libcrypto_out}")" \
    "$(dirname "${libssl_out}")" \
    "${include_out}" \
    "$(dirname "${checker_out}")" \
    "$(dirname "${license_out}")"
cp "${work}/build/crypto/libcrypto.a" "${libcrypto_out}"
cp "${work}/build/ssl/libssl.a" "${libssl_out}"
cp -R "${work}/src/include/." "${include_out}/"
cp "${work}/src/LICENSE" "${license_out}"

"${readelf_bin}" -h "${libcrypto_out}" > "${work}/libcrypto.headers"
"${readelf_bin}" -h "${libssl_out}" > "${work}/libssl.headers"
if [[ "${target_triplet}" = aarch64-* ]]; then
    grep -q 'Machine:.*AArch64' "${work}/libcrypto.headers"
    grep -q 'Machine:.*AArch64' "${work}/libssl.headers"
    ! grep -q 'Machine:.*X86-64' "${work}/libcrypto.headers"
    ! grep -q 'Machine:.*X86-64' "${work}/libssl.headers"
else
    grep -q 'Machine:.*X86-64' "${work}/libcrypto.headers"
    grep -q 'Machine:.*X86-64' "${work}/libssl.headers"
fi

"${cc_bin}" \
    --target="${target_triplet}" \
    --sysroot="${sysroot}" \
    -resource-dir="${resource_dir}" \
    --rtlib=compiler-rt \
    -fuse-ld=lld \
    -O2 -static \
    -I"${work}/src/include" \
    "${checker_source}" "${libcrypto_out}" \
    -ldl -pthread -lm -o "${checker_out}"
if "${readelf_bin}" -l "${checker_out}" | grep -q 'INTERP'; then
    echo "BoringCrypto verifier unexpectedly contains an ELF interpreter" >&2
    exit 1
fi
if "${readelf_bin}" -d "${checker_out}" 2>/dev/null | grep -q 'NEEDED'; then
    echo "BoringCrypto verifier unexpectedly contains a dynamic dependency" >&2
    exit 1
fi
"${checker_out}"

crypto_sha="$(sha256sum "${libcrypto_out}" | awk '{print $1}')"
ssl_sha="$(sha256sum "${libssl_out}" | awk '{print $1}')"
checker_sha="$(sha256sum "${checker_out}" | awk '{print $1}')"
printf '%s\n' \
    '{' \
    '  "schema": 1,' \
    '  "backend": "boringcrypto",' \
    '  "certificate": "CMVP #5296",' \
    '  "module_name": "BoringCrypto",' \
    '  "module_version": "2023042800",' \
    '  "source_commit": "a430310d6563c0734ddafca7731570dfb683dc19",' \
    '  "arch": "'"${arch}"'",' \
    '  "libc": "musl",' \
    '  "musl_revision": "'"${musl_revision}"'",' \
    '  "libcrypto_sha256": "'"${crypto_sha}"'",' \
    '  "libssl_sha256": "'"${ssl_sha}"'",' \
    '  "checker_sha256": "'"${checker_sha}"'",' \
    '  "linkage": "static",' \
    '  "cmake": "3.27.4",' \
    '  "go": "1.21.1",' \
    '  "ninja": "1.11.1",' \
    '  "operational_environment_status": "not-listed-on-cmvp-5296",' \
    '  "service_indicator": "per-service"' \
    '}' > "${manifest_out}"
rm -rf "${work}"
trap - EXIT
"""

    ctx.actions.run_shell(
        arguments = [
            ctx.file.source_root_marker.path,
            ctx.file.checker_source.path,
            libcrypto.path,
            libssl.path,
            include_dir.path,
            checker.path,
            license_file.path,
            manifest.path,
            platform.arch,
            platform.boringssl_processor,
            platform.cmake_bin,
            ninja.binary.path,
            platform.go_bin,
            platform.clang_cc,
            platform.clang_cxx,
            platform.llvm_ar,
            platform.llvm_ranlib,
            platform.llvm_readelf,
            platform.musl_triplet,
            platform.sysroot_path,
            platform.musl_revision,
        ],
        command = command,
        env = {
            "GOFLAGS": "-buildvcs=false",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "SOURCE_DATE_EPOCH": "0",
        },
        execution_requirements = {"block-network": "1"},
        inputs = _all_inputs(
            [ctx.attr.source],
            [ctx.file.checker_source, ctx.file.source_root_marker],
            [
                platform.clang_files,
                platform.cmake_files,
                platform.go_files,
                platform.sysroot_files,
                ninja.files,
            ],
        ),
        mnemonic = "BoringCryptoFipsBuild",
        outputs = [libcrypto, libssl, include_dir, checker, license_file, manifest],
        progress_message = "Building validated BoringCrypto for %s" % platform.arch,
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([libcrypto, libssl, include_dir, checker, license_file, manifest])),
        FipsCryptoInfo(
            backend = "boringcrypto",
            certificate = "CMVP #5296",
            include_dir = include_dir,
            manifest = manifest,
            module_name = "BoringCrypto",
            module_version = "2023042800",
            runtime_files = depset([checker, license_file]),
            service_indicator = "per-service",
            static_libs = depset([libssl, libcrypto], order = "preorder"),
        ),
    ]

boringcrypto_fips = rule(
    implementation = _boringcrypto_fips_impl,
    attrs = {
        "checker_source": attr.label(
            allow_single_file = [".c"],
            default = "//runtime:boring_fips_check.c",
        ),
        "ninja": attr.label(
            cfg = "exec",
            default = "//fips/toolchains:policy_ninja",
            providers = [PolicyNinjaInfo],
        ),
        "source": attr.label(
            default = "@boringssl_src//:srcs",
        ),
        "source_root_marker": attr.label(
            allow_single_file = True,
            default = "@boringssl_src//:CMakeLists.txt",
        ),
    },
    doc = "Builds the exact BoringCrypto module validated by CMVP #5296.",
    toolchains = [_TOOLCHAIN_TYPE],
)

def _openssl_fips_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    make = foreign_tool(ctx, MAKE_TOOLCHAIN)
    libcrypto = ctx.actions.declare_file(ctx.label.name + "/lib/libcrypto.a")
    libssl = ctx.actions.declare_file(ctx.label.name + "/lib/libssl.a")
    include_dir = ctx.actions.declare_directory(ctx.label.name + "/include")
    openssl_bin = ctx.actions.declare_file(ctx.label.name + "/bin/openssl")
    fips_module = ctx.actions.declare_file(ctx.label.name + "/lib/ossl-modules/fips.so")
    config = ctx.actions.declare_file(ctx.label.name + "/ssl/openssl-fips.cnf")
    core_license = ctx.actions.declare_file(ctx.label.name + "/licenses/openssl-core.txt")
    fips_license = ctx.actions.declare_file(ctx.label.name + "/licenses/openssl-fips.txt")
    manifest = ctx.actions.declare_file(ctx.label.name + "/FIPS_BUILD.json")

    command = """
set -euo pipefail

core_root="$(dirname "$1")"
exec_root="${PWD}"
resolve_tool() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        */*) printf '%s/%s\n' "${exec_root}" "$1" ;;
        *) command -v "$1" ;;
    esac
}
absolutize_flags() {
    local flags="$1"
    flags="${flags//external\\//${exec_root}\\/external\\/}"
    flags="${flags//bazel-out\\//${exec_root}\\/bazel-out\\/}"
    printf '%s\n' "${flags}"
}
fips_root="$(dirname "$2")"
config_source="$3"
libcrypto_out="$4"
libssl_out="$5"
include_out="$6"
openssl_out="$7"
fips_out="$8"
config_out="$9"
core_license_out="${10}"
fips_license_out="${11}"
manifest_out="${12}"
arch="${13}"
openssl_target="${14}"
make_bin="$(resolve_tool "${15}")"
cc_bin="$(resolve_tool "${16}")"
cflags="$(absolutize_flags "${17}")"
linkflags="$(absolutize_flags "${18}")"

mkdir -p "${include_out}"
work="${exec_root}/${include_out}/.build-work"
mkdir -p "${work}"
trap 'rm -rf "${work}"' EXIT
export TMPDIR="${work}/tmp"
mkdir -p "${TMPDIR}"
cp -RL "${core_root}" "${work}/core-src"
cp -RL "${fips_root}" "${work}/fips-src"
core_prefix="${work}/core"
fips_prefix="${work}/fips"

(
    cd "${work}/fips-src"
    CC="${cc_bin}" CFLAGS="-O2 -fPIC ${cflags}" LDFLAGS="${linkflags}" \
        ./Configure "${openssl_target}" \
        --prefix="${fips_prefix}" \
        --openssldir="${fips_prefix}/ssl" \
        --libdir=lib \
        enable-fips no-tests
    "${make_bin}" -j"$(nproc)"
    "${make_bin}" install_fips
)

(
    cd "${work}/core-src"
    CC="${cc_bin}" CFLAGS="-O2 -fPIC ${cflags}" LDFLAGS="${linkflags}" \
        ./Configure "${openssl_target}" \
        --prefix="${core_prefix}" \
        --openssldir="${core_prefix}/ssl" \
        --libdir=lib \
        no-shared no-tests
    "${make_bin}" -j"$(nproc)" build_sw
    "${make_bin}" install_sw
)

mkdir -p \
    "$(dirname "${libcrypto_out}")" \
    "$(dirname "${libssl_out}")" \
    "${include_out}" \
    "$(dirname "${openssl_out}")" \
    "$(dirname "${fips_out}")" \
    "$(dirname "${config_out}")" \
    "$(dirname "${core_license_out}")"
cp "${core_prefix}/lib/libcrypto.a" "${libcrypto_out}"
cp "${core_prefix}/lib/libssl.a" "${libssl_out}"
cp -R "${core_prefix}/include/." "${include_out}/"
cp "${core_prefix}/bin/openssl" "${openssl_out}"
cp "${fips_prefix}/lib/ossl-modules/fips.so" "${fips_out}"
cp "${config_source}" "${config_out}"
cp "${work}/core-src/LICENSE.txt" "${core_license_out}"
cp "${work}/fips-src/LICENSE.txt" "${fips_license_out}"

module_conf="${work}/fipsmodule.cnf"
OPENSSL_CONF=/dev/null OPENSSL_MODULES="$(dirname "${fips_out}")" \
    "${openssl_out}" fipsinstall \
        -module "${fips_out}" \
        -out "${module_conf}" \
        -pedantic
OPENSSL_CONF="${config_out}" \
OPENSSL_MODULES="$(dirname "${fips_out}")" \
FIPS_MODULE_CONF="${module_conf}" \
    "${openssl_out}" list -providers -verbose

crypto_sha="$(sha256sum "${libcrypto_out}" | awk '{print $1}')"
ssl_sha="$(sha256sum "${libssl_out}" | awk '{print $1}')"
module_sha="$(sha256sum "${fips_out}" | awk '{print $1}')"
printf '%s\n' \
    '{' \
    '  "schema": 1,' \
    '  "backend": "openssl",' \
    '  "certificate": "CMVP #4985",' \
    '  "module_name": "OpenSSL FIPS Provider",' \
    '  "module_version": "3.1.2",' \
    '  "core_version": "3.5.7",' \
    '  "arch": "'"${arch}"'",' \
    '  "libcrypto_sha256": "'"${crypto_sha}"'",' \
    '  "libssl_sha256": "'"${ssl_sha}"'",' \
    '  "fips_module_sha256": "'"${module_sha}"'",' \
    '  "linkage": "static-core-dynamic-provider",' \
    '  "service_indicator": "provider-properties-fips=yes"' \
    '}' > "${manifest_out}"
rm -rf "${work}"
trap - EXIT
"""

    ctx.actions.run_shell(
        arguments = [
            ctx.file.core_root_marker.path,
            ctx.file.fips_root_marker.path,
            ctx.file.openssl_config.path,
            libcrypto.path,
            libssl.path,
            include_dir.path,
            openssl_bin.path,
            fips_module.path,
            config.path,
            core_license.path,
            fips_license.path,
            manifest.path,
            platform.arch,
            platform.openssl_target,
            make.path,
            platform.clang_cc,
            _compile_flags(platform),
            _link_flags(platform),
        ],
        command = command,
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        inputs = _all_inputs(
            [ctx.attr.core_source, ctx.attr.fips_source],
            [ctx.file.core_root_marker, ctx.file.fips_root_marker, ctx.file.openssl_config],
            [make.inputs, platform.clang_files, platform.sysroot_files],
        ),
        mnemonic = "OpenSslFipsBuild",
        outputs = [
            libcrypto,
            libssl,
            include_dir,
            openssl_bin,
            fips_module,
            config,
            core_license,
            fips_license,
            manifest,
        ],
        progress_message = "Building validated OpenSSL FIPS provider for %s" % platform.arch,
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(files = depset([
            libcrypto,
            libssl,
            include_dir,
            openssl_bin,
            fips_module,
            config,
            core_license,
            fips_license,
            manifest,
        ])),
        FipsCryptoInfo(
            backend = "openssl",
            certificate = "CMVP #4985",
            include_dir = include_dir,
            manifest = manifest,
            module_name = "OpenSSL FIPS Provider",
            module_version = "3.1.2",
            runtime_files = depset([openssl_bin, fips_module, config, core_license, fips_license]),
            service_indicator = "provider-properties-fips=yes",
            static_libs = depset([libssl, libcrypto], order = "preorder"),
        ),
    ]

openssl_fips = rule(
    implementation = _openssl_fips_impl,
    attrs = {
        "core_root_marker": attr.label(
            allow_single_file = True,
            default = "@openssl_core_src//:Configure",
        ),
        "core_source": attr.label(
            default = "@openssl_core_src//:srcs",
        ),
        "fips_root_marker": attr.label(
            allow_single_file = True,
            default = "@openssl_fips_src//:Configure",
        ),
        "fips_source": attr.label(
            default = "@openssl_fips_src//:srcs",
        ),
        "openssl_config": attr.label(
            allow_single_file = [".cnf"],
            default = "//runtime:openssl-fips.cnf",
        ),
    },
    doc = "Builds a static OpenSSL 3.5.7 core with validated provider 3.1.2.",
    toolchains = [_TOOLCHAIN_TYPE, MAKE_TOOLCHAIN],
)
