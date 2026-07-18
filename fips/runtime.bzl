"""OTP and Elixir distribution rule backed by FipsCryptoInfo."""

load("//fips:providers.bzl", "FipsCryptoInfo", "FipsRuntimeInfo")
load(
    "//fips/private:tooling.bzl",
    "MAKE_TOOLCHAIN",
    "foreign_tool",
)

_TOOLCHAIN_TYPE = "//fips:toolchain_type"

def _file_named(files, basename, required = True):
    for file in files:
        if file.basename == basename:
            return file
    if required:
        fail("required FIPS input %s was not provided" % basename)
    return None

def _optional_path(file):
    return file.path if file else "-"

def _compile_flags(platform):
    return " ".join([
        "--target=" + platform.musl_triplet,
        "--sysroot=" + platform.sysroot_path,
        "-resource-dir=" + platform.sysroot_path + "/usr/lib/clang/16",
    ])

def _link_flags(platform):
    return " ".join([
        _compile_flags(platform),
        "--rtlib=compiler-rt",
        "-fuse-ld=lld",
        "-static",
        "-no-pie",
        "-Wl,-S",
        "-Wl,-z,relro,-z,now",
    ])

def _fips_elixir_runtime_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    make = foreign_tool(ctx, MAKE_TOOLCHAIN)
    crypto = ctx.attr.crypto[FipsCryptoInfo]
    static_libs = crypto.static_libs.to_list()
    runtime_files = crypto.runtime_files.to_list()
    libssl = _file_named(static_libs, "libssl.a")
    libcrypto = _file_named(static_libs, "libcrypto.a")
    checker = _file_named(runtime_files, "boring-fips-check", required = False)
    openssl_bin = _file_named(runtime_files, "openssl", required = False)
    fips_module = _file_named(runtime_files, "fips.so", required = False)
    openssl_config = _file_named(runtime_files, "openssl-fips.cnf", required = False)

    if crypto.backend == "boringcrypto":
        if not checker:
            fail("BoringCrypto runtime requires boring-fips-check")
    elif crypto.backend == "openssl":
        if not openssl_bin or not fips_module or not openssl_config:
            fail("OpenSSL runtime requires openssl, fips.so, and openssl-fips.cnf")
    else:
        fail("unsupported FIPS backend: %s" % crypto.backend)

    distribution = ctx.actions.declare_file(ctx.label.name + ".tar.gz")
    manifest = ctx.actions.declare_file(ctx.label.name + ".json")
    scratch = ctx.actions.declare_directory(ctx.label.name + ".scratch")
    direct_inputs = [
        ctx.file.otp_root_marker,
        ctx.file.otp_empty_dirs,
        ctx.file.elixir_root_marker,
        ctx.file.compat_root_marker,
        ctx.file.boring_boot,
        ctx.file.openssl_boot,
        ctx.file.boring_launcher,
        ctx.file.openssl_launcher,
        crypto.include_dir,
        crypto.manifest,
        libssl,
        libcrypto,
    ] + runtime_files

    command = """
set -euo pipefail

otp_root="$(dirname "$1")"
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
elixir_root="$(dirname "$2")"
crypto_include="$3"
libssl="$4"
libcrypto="$5"
compat_marker="$(resolve_tool "$6")"
boring_boot="$7"
openssl_boot="$8"
boring_launcher="$9"
openssl_launcher="${10}"
distribution_out="${11}"
manifest_out="${12}"
backend="${13}"
arch="${14}"
otp_version="${15}"
elixir_version="${16}"
checker="${17}"
openssl_bin="${18}"
fips_module="${19}"
openssl_config="${20}"
crypto_manifest="${21}"
make_bin="$(resolve_tool "${22}")"
cc_bin="$(resolve_tool "${23}")"
cxx_bin="$(resolve_tool "${24}")"
cflags="$(absolutize_flags "${25}")"
cxxflags="$(absolutize_flags "${26}")"
linkflags="$(absolutize_flags "${27}")"
scratch="$(resolve_tool "${28}")"
sysroot="$(resolve_tool "${29}")"
otp_empty_dirs="$(resolve_tool "${30}")"
ar_bin="$(resolve_tool "${31}")"
ranlib_bin="$(resolve_tool "${32}")"
readelf_bin="$(resolve_tool "${33}")"
musl_revision="${34}"
musl_triplet="${35}"
build_triplet="${36}"
build_sysroot="$(resolve_tool "${37}")"
build_compiler_rt="$(resolve_tool "${38}")"
shift 38

mkdir -p "${scratch}"
work="${scratch}/work"
mkdir -p "${work}"
trap 'rm -rf "${work}"' EXIT
export TMPDIR="${work}/tmp"
mkdir -p "${TMPDIR}"
cp -RL "${otp_root}" "${work}/otp"
cp -RL "${elixir_root}" "${work}/elixir"
otp_src="${work}/otp"
elixir_src="${work}/elixir"
while IFS= read -r relative_dir; do
    if [ -n "${relative_dir}" ]; then
        mkdir -p "${otp_src}/${relative_dir#./}"
    fi
done < "${otp_empty_dirs}"
stage="${work}/rootfs"
prefix=/opt/fips-elixir
crypto_root="${work}/crypto"
mkdir -p "${crypto_root}/include" "${crypto_root}/lib" "${stage}${prefix}/licenses"
cp -R "${crypto_include}/." "${crypto_root}/include/"
cp "${libssl}" "${crypto_root}/lib/libssl.a"
cp "${libcrypto}" "${crypto_root}/lib/libcrypto.a"

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=0
jobs="$(nproc)"
static_libs="-Wl,--start-group ${crypto_root}/lib/libssl.a ${crypto_root}/lib/libcrypto.a -lc++ -lc++abi -lunwind -Wl,--end-group -ldl -pthread -lm"
build_erl_path="${otp_src}/bin"

if [ "${build_triplet}" != "${musl_triplet}" ]; then
    host_otp="${work}/host-otp"
    cp -RL "${otp_root}" "${host_otp}"
    while IFS= read -r relative_dir; do
        if [ -n "${relative_dir}" ]; then
            mkdir -p "${host_otp}/${relative_dir#./}"
        fi
    done < "${otp_empty_dirs}"
    clang_root="$(dirname "$(dirname "${cc_bin}")")"
    host_cflags="--target=${build_triplet} --sysroot=${build_sysroot} -resource-dir=${clang_root}/lib/clang/16 -O2"
    host_linkflags="${host_cflags} -fuse-ld=lld -no-pie"
    (
        cd "${host_otp}"
        env \
            CC="${cc_bin}" \
            CXX="${cxx_bin}" \
            AR="${ar_bin}" \
            RANLIB="${ranlib_bin}" \
            CFLAGS="${host_cflags}" \
            CXXFLAGS="${host_cflags}" \
            LDFLAGS="${host_linkflags}" \
            LIBS="${build_compiler_rt}" \
            ./configure \
                --build="${build_triplet}" \
                --host="${build_triplet}" \
                --enable-bootstrap-only \
                --enable-builtin-zlib \
                --disable-jit \
                --disable-pie \
                --without-termcap \
                --without-javac \
                --without-wx \
                --without-ssl
        if ! "${make_bin}" -j"${jobs}" >"${work}/host-otp-build.log" 2>&1; then
            tail -200 "${work}/host-otp-build.log"
            exit 1
        fi
    )
    build_erl_path="${host_otp}/bootstrap/bin"
    test -x "${build_erl_path}/erl"
    PATH="${build_erl_path}:${PATH}"
    export PATH
fi

if [ "${backend}" = boringcrypto ]; then
    compat_root="$(dirname "$(dirname "${compat_marker}")")"
    configure_env=(
        "CC=${cc_bin}"
        "CXX=${cxx_bin}"
        "AR=${ar_bin}"
        "RANLIB=${ranlib_bin}"
        "CFLAGS=-O2 ${cflags}"
        "CXXFLAGS=-O2 ${cxxflags}"
        "STATIC_CFLAGS=-O2 ${cflags}"
        "CPPFLAGS=-I${compat_root}"
        "LDFLAGS=${linkflags}"
        "LIBS=${static_libs}"
    )
    configure_extra=(--disable-evp-dh --disable-evp-hmac)
else
    mkdir -p "${crypto_root}/bin" "${crypto_root}/lib/ossl-modules" "${crypto_root}/ssl"
    cp "${openssl_bin}" "${crypto_root}/bin/openssl"
    cp "${fips_module}" "${crypto_root}/lib/ossl-modules/fips.so"
    cp "${openssl_config}" "${crypto_root}/ssl/openssl-fips.cnf"
    fips_module_conf="${work}/fipsmodule.cnf"
    OPENSSL_CONF=/dev/null OPENSSL_MODULES="${crypto_root}/lib/ossl-modules" \
        "${crypto_root}/bin/openssl" fipsinstall \
            -module "${crypto_root}/lib/ossl-modules/fips.so" \
            -out "${fips_module_conf}" \
            -pedantic >/dev/null
    export OPENSSL_CONF="${crypto_root}/ssl/openssl-fips.cnf"
    export OPENSSL_MODULES="${crypto_root}/lib/ossl-modules"
    export FIPS_MODULE_CONF="${fips_module_conf}"
    configure_env=(
        "CC=${cc_bin}"
        "CXX=${cxx_bin}"
        "AR=${ar_bin}"
        "RANLIB=${ranlib_bin}"
        "CFLAGS=-O2 ${cflags}"
        "CXXFLAGS=-O2 ${cxxflags}"
        "STATIC_CFLAGS=-O2 ${cflags}"
        "LDFLAGS=${linkflags}"
        "LIBS=${static_libs}"
    )
    configure_extra=()
fi

if [ "${build_triplet}" != "${musl_triplet}" ]; then
    configure_env+=(
        "erl_xcomp_sysroot=${sysroot}"
        "erl_xcomp_isysroot=${sysroot}"
        "erl_xcomp_bigendian=no"
        "erl_xcomp_double_middle_endian=no"
    )
fi

(
    cd "${otp_src}"
    env "${configure_env[@]}" ./configure \
        --build="${build_triplet}" \
        --host="${musl_triplet}" \
        --prefix="${prefix}" \
        --with-ssl="${crypto_root}" \
        --with-ssl-lib-subdir=lib \
        --disable-dynamic-ssl-lib \
        --with-ssl-rpath=no \
        --enable-fips \
        --enable-static-nifs=yes \
        --enable-static-drivers=yes \
        --enable-builtin-zlib \
        --enable-builtin-zstd \
        --disable-jit \
        --disable-pie \
        --disable-systemd \
        --without-termcap \
        --without-javac \
        --without-wx \
        --without-debugger \
        --without-observer \
        --without-et \
        --without-odbc \
        --without-runtime_tools \
        "${configure_extra[@]}"
    "${make_bin}" -C lib \
        ERL_TOP="${otp_src}" \
        OVERRIDE_TARGET="${musl_triplet}" \
        BUILD_STATIC_LIBS=1 \
        TYPE=opt \
        static_lib
    if ! "${make_bin}" -j"${jobs}" \
        OVERRIDE_TARGET="${musl_triplet}" \
        >"${work}/otp-build.log" 2>&1; then
        tail -200 "${work}/otp-build.log"
        exit 1
    fi
)

(
    cd "${otp_src}"
    "${make_bin}" install \
        OVERRIDE_TARGET="${musl_triplet}" \
        DESTDIR="${stage}"
)
verify_erl="${stage}${prefix}/bin/erl"

if [ "${backend}" = boringcrypto ]; then
    (
        cd "${otp_src}"
        ERL_ROOTDIR="${stage}${prefix}/lib/erlang" \
            "${verify_erl}" -crypto fips_mode true -noshell -eval '
            {ok, _} = application:ensure_all_started(crypto),
            enabled = crypto:info_fips(),
            #{link_type := static, cryptolib_version_linked := Linked} = crypto:info(),
            true = string:find(Linked, "BoringSSL") =/= nomatch,
            false = crypto:enable_fips_mode(false),
            enabled = crypto:info_fips(),
            {'EXIT', {{notsup, _, _}, _}} =
                (catch crypto:hash(md5, <<"rules_fips">>)),
            <<227,176,196,66,152,252,28,20,154,251,244,200,153,111,185,36,
              39,174,65,228,100,155,147,76,164,149,153,27,120,82,184,85>> =
                crypto:hash(sha256, <<>>),
            halt(0).'
    )
else
    (
        cd "${otp_src}"
        ERL_ROOTDIR="${stage}${prefix}/lib/erlang" \
            "${verify_erl}" -crypto fips_mode true -noshell -eval '
            {ok, _} = application:ensure_all_started(crypto),
            enabled = crypto:info_fips(),
            #{link_type := static,
              fips_provider_available := true,
              fips_provider_buildinfo := BuildInfo} = crypto:info(),
            true = string:find(BuildInfo, "3.1.2") =/= nomatch,
            <<227,176,196,66,152,252,28,20,154,251,244,200,153,111,185,36,
              39,174,65,228,100,155,147,76,164,149,153,27,120,82,184,85>> =
                crypto:hash(sha256, <<>>),
            halt(0).'
    )
fi

(
    cd "${elixir_src}"
    elixir_home="${work}/elixir-home"
    elixir_erl_flags=""
    if [ "${build_triplet}" != "${musl_triplet}" ]; then
        # The native bootstrap intentionally contains only the applications
        # required to cross-build OTP. Elixir's first compilation step uses
        # `erl -make`, whose architecture-independent module was produced by
        # the completed target OTP build above.
        elixir_erl_flags="-pa ${otp_src}/lib/tools/ebin"
    fi
    mkdir -p "${elixir_home}"
    if ! PATH="${build_erl_path}:${PATH}" \
        HOME="${elixir_home}" \
        ERL_FLAGS="${elixir_erl_flags}" \
        ERL_COMPILER_OPTIONS=deterministic \
            "${make_bin}" -j"${jobs}" >"${work}/elixir-build.log" 2>&1; then
        tail -200 "${work}/elixir-build.log"
        exit 1
    fi
    PATH="${build_erl_path}:${PATH}" \
        HOME="${elixir_home}" \
        ERL_FLAGS="${elixir_erl_flags}" \
        "${make_bin}" install PREFIX="${prefix}" DESTDIR="${stage}"
)

install_root="${stage}${prefix}"
mkdir -p "${install_root}/lib/fips_boot/ebin" "${install_root}/licenses"
if [ "${backend}" = boringcrypto ]; then
    "${build_erl_path}/erlc" -o "${install_root}/lib/fips_boot/ebin" "${boring_boot}"
    mv "${install_root}/bin/elixir" "${install_root}/bin/elixir.real"
    cp "${boring_launcher}" "${install_root}/bin/elixir"
    chmod 0755 "${install_root}/bin/elixir"
    cp "${checker}" "${install_root}/bin/boring-fips-check"
    chmod 0755 "${install_root}/bin/boring-fips-check"
else
    "${build_erl_path}/erlc" -o "${install_root}/lib/fips_boot/ebin" "${openssl_boot}"
    mv "${install_root}/bin/elixir" "${install_root}/bin/elixir.real"
    cp "${openssl_launcher}" "${install_root}/bin/elixir"
    chmod 0755 "${install_root}/bin/elixir"
    mkdir -p "${install_root}/lib/ossl-modules" "${install_root}/ssl"
    cp "${openssl_bin}" "${install_root}/bin/openssl"
    cp "${fips_module}" "${install_root}/lib/ossl-modules/fips.so"
    cp "${openssl_config}" "${install_root}/ssl/openssl-fips.cnf"
fi

cp "${otp_src}/LICENSE.txt" "${install_root}/licenses/erlang-otp.txt"
cp "${elixir_src}/LICENSE" "${install_root}/licenses/elixir.txt"
cp -R "${sysroot}/usr/share/licenses/." "${install_root}/licenses/"
for runtime_file in "$@"; do
    case "$(basename "${runtime_file}")" in
        *.txt|LICENSE|LICENSE.txt) cp "${runtime_file}" "${install_root}/licenses/" ;;
    esac
done
cp "${crypto_manifest}" "${install_root}/FIPS_CRYPTO.json"
find "${install_root}" -type f \\( \
    -name '*.a' -o \
    -name '*.la' -o \
    -name '*.so' -o \
    -name '*.so.*' \
\\) -delete

elf_count=0
while IFS= read -r -d '' candidate; do
    if "${readelf_bin}" -h "${candidate}" >/dev/null 2>&1; then
        elf_count=$((elf_count + 1))
        if "${readelf_bin}" -l "${candidate}" 2>/dev/null | grep -q 'INTERP'; then
            echo "packaged ELF contains an interpreter: ${candidate}" >&2
            exit 1
        fi
        if "${readelf_bin}" -d "${candidate}" 2>/dev/null | grep -q 'NEEDED'; then
            echo "packaged ELF contains a dynamic dependency: ${candidate}" >&2
            exit 1
        fi
    fi
done < <(find "${install_root}" -type f -print0)
test "${elf_count}" -gt 0

printf '%s\n' \
    '{' \
    '  "schema": 1,' \
    '  "backend": "'"${backend}"'",' \
    '  "arch": "'"${arch}"'",' \
    '  "otp": "'"${otp_version}"'",' \
    '  "elixir": "'"${elixir_version}"'",' \
    '  "prefix": "/opt/fips-elixir",' \
    '  "libc": "musl",' \
    '  "musl_revision": "'"${musl_revision}"'",' \
    '  "crypto_linkage": "static",' \
    '  "native_linkage": "fully-static",' \
    '  "packaged_elf_count": '"${elf_count}"',' \
    '  "shared_objects": 0,' \
    '  "operational_environment_status": "not-listed-on-cmvp-5296"' \
    '}' > "${manifest_out}"
cp "${manifest_out}" "${install_root}/FIPS_RUNTIME.json"

tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
    -C "${stage}" -czf "${distribution_out}" opt
rm -rf "${work}"
trap - EXIT
"""

    ctx.actions.run_shell(
        arguments = [
            ctx.file.otp_root_marker.path,
            ctx.file.elixir_root_marker.path,
            crypto.include_dir.path,
            libssl.path,
            libcrypto.path,
            ctx.file.compat_root_marker.path,
            ctx.file.boring_boot.path,
            ctx.file.openssl_boot.path,
            ctx.file.boring_launcher.path,
            ctx.file.openssl_launcher.path,
            distribution.path,
            manifest.path,
            crypto.backend,
            platform.arch,
            ctx.attr.otp_version,
            ctx.attr.elixir_version,
            _optional_path(checker),
            _optional_path(openssl_bin),
            _optional_path(fips_module),
            _optional_path(openssl_config),
            crypto.manifest.path,
            make.path,
            platform.clang_cc,
            platform.clang_cxx,
            _compile_flags(platform),
            _compile_flags(platform) + " -stdlib=libc++",
            _link_flags(platform),
            scratch.path,
            platform.sysroot_path,
            ctx.file.otp_empty_dirs.path,
            platform.llvm_ar,
            platform.llvm_ranlib,
            platform.llvm_readelf,
            platform.musl_revision,
            platform.musl_triplet,
            platform.build_triplet,
            platform.build_sysroot_path,
            platform.build_compiler_rt_path,
        ] + [file.path for file in runtime_files],
        command = command,
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "SOURCE_DATE_EPOCH": "0",
        },
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = direct_inputs,
            transitive = [
                ctx.attr.otp_source[DefaultInfo].files,
                ctx.attr.elixir_source[DefaultInfo].files,
                ctx.attr.compat_headers[DefaultInfo].files,
                make.inputs,
                platform.build_compiler_rt_files,
                platform.build_sysroot_files,
                platform.clang_files,
                platform.sysroot_files,
            ],
        ),
        mnemonic = "FipsElixirRuntimeBuild",
        outputs = [distribution, manifest, scratch],
        progress_message = "Building OTP %s and Elixir %s with %s for %s" % (
            ctx.attr.otp_version,
            ctx.attr.elixir_version,
            crypto.backend,
            platform.arch,
        ),
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([distribution, manifest])),
        FipsRuntimeInfo(
            backend = crypto.backend,
            distribution = distribution,
            elixir_version = ctx.attr.elixir_version,
            manifest = manifest,
            otp_version = ctx.attr.otp_version,
        ),
    ]

fips_elixir_runtime = rule(
    implementation = _fips_elixir_runtime_impl,
    attrs = {
        "boring_boot": attr.label(
            allow_single_file = [".erl"],
            default = "//runtime:fips_boot_boringssl.erl",
        ),
        "boring_launcher": attr.label(
            allow_single_file = True,
            default = "//runtime:elixir-boringssl",
        ),
        "compat_headers": attr.label(
            default = "//compat/boringssl:headers",
        ),
        "compat_root_marker": attr.label(
            allow_single_file = [".h"],
            default = "//compat/boringssl:openssl/modes.h",
        ),
        "crypto": attr.label(
            mandatory = True,
            providers = [FipsCryptoInfo],
        ),
        "elixir_root_marker": attr.label(
            allow_single_file = True,
            default = "@elixir_src//:Makefile",
        ),
        "elixir_source": attr.label(
            default = "@elixir_src//:srcs",
        ),
        "elixir_version": attr.string(default = "1.20.2"),
        "openssl_boot": attr.label(
            allow_single_file = [".erl"],
            default = "//runtime:fips_boot.erl",
        ),
        "openssl_launcher": attr.label(
            allow_single_file = True,
            default = "//runtime:elixir",
        ),
        "otp_root_marker": attr.label(
            allow_single_file = True,
            default = "@otp_src//:configure",
        ),
        "otp_empty_dirs": attr.label(
            allow_single_file = True,
            default = "@otp_src//:rules_fips_empty_dirs.txt",
        ),
        "otp_source": attr.label(
            default = "@otp_src//:srcs",
        ),
        "otp_version": attr.string(default = "29.0.3"),
    },
    doc = "Builds a relocatable /opt/fips-elixir distribution tarball.",
    toolchains = [_TOOLCHAIN_TYPE, MAKE_TOOLCHAIN],
)
