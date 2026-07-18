#!/usr/bin/env bash
set -Eeuo pipefail

jobs="${BUILD_JOBS:-$(nproc)}"
build_root=/build
install_root=/opt/fips-elixir
fips_stage=/opt/openssl-fips-module
openssl_src=${build_root}/openssl
fips_src=${build_root}/openssl-fips

case "$(uname -m)" in
    x86_64) openssl_target=linux-x86_64 ;;
    aarch64) openssl_target=linux-aarch64 ;;
    *)
        echo "Unsupported target architecture: $(uname -m)" >&2
        exit 64
        ;;
esac

echo "==> Building exact validated OpenSSL FIPS provider ${OPENSSL_FIPS_VERSION}"
(
    cd "${fips_src}"
    CFLAGS="-O2 -fPIC" ./Configure "${openssl_target}" \
        --prefix="${fips_stage}" \
        --openssldir="${fips_stage}/ssl" \
        --libdir=lib \
        enable-fips no-tests
    make -j"${jobs}"
    make install_fips
)

echo "==> Building static OpenSSL core ${OPENSSL_VERSION}"
(
    cd "${openssl_src}"
    CFLAGS="-O2 -fPIC" ./Configure "${openssl_target}" \
        --prefix="${install_root}" \
        --openssldir="${install_root}/ssl" \
        --libdir=lib \
        no-shared no-tests
    make -j"${jobs}" build_sw
    make install_sw
)

install -d \
    "${install_root}/lib/ossl-modules" \
    "${install_root}/licenses" \
    "${install_root}/ssl"
install -m 0755 "${fips_stage}/lib/ossl-modules/fips.so" \
    "${install_root}/lib/ossl-modules/fips.so"
install -m 0644 "${openssl_src}/LICENSE.txt" \
    "${install_root}/licenses/openssl-core-${OPENSSL_VERSION}.txt"
install -m 0644 "${fips_src}/LICENSE.txt" \
    "${install_root}/licenses/openssl-fips-${OPENSSL_FIPS_VERSION}.txt"
install -m 0644 /experiment/runtime/openssl-fips.cnf \
    "${install_root}/ssl/openssl-fips.cnf"

echo "==> Installing and self-testing the bundled FIPS provider"
fips_module_conf=$(mktemp)
OPENSSL_CONF=/dev/null \
OPENSSL_MODULES="${install_root}/lib/ossl-modules" \
    "${install_root}/bin/openssl" fipsinstall \
        -module "${install_root}/lib/ossl-modules/fips.so" \
        -out "${fips_module_conf}" \
        -pedantic

OPENSSL_CONF="${install_root}/ssl/openssl-fips.cnf" \
OPENSSL_MODULES="${install_root}/lib/ossl-modules" \
FIPS_MODULE_CONF="${fips_module_conf}" \
    "${install_root}/bin/openssl" list -providers -verbose
