#!/usr/bin/env bash
set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

jobs="${BUILD_JOBS:-$(nproc)}"
install_root=/opt/fips-elixir
elixir_src=/build/elixir
fips_module_conf=$(mktemp)

OPENSSL_CONF=/dev/null \
OPENSSL_MODULES="${install_root}/lib/ossl-modules" \
    "${install_root}/bin/openssl" fipsinstall \
        -module "${install_root}/lib/ossl-modules/fips.so" \
        -out "${fips_module_conf}" \
        -pedantic >/dev/null

export OPENSSL_CONF="${install_root}/ssl/openssl-fips.cnf"
export OPENSSL_MODULES="${install_root}/lib/ossl-modules"
export FIPS_MODULE_CONF="${fips_module_conf}"

echo "==> Building Elixir against the custom OTP"
(
    cd "${elixir_src}"
    PATH="${install_root}/bin:${PATH}" make -j"${jobs}"
    PATH="${install_root}/bin:${PATH}" make install PREFIX="${install_root}"
)

echo "==> Installing FIPS-on Elixir launcher"
mkdir -p "${install_root}/lib/fips_boot/ebin"
"${install_root}/bin/erlc" \
    -o "${install_root}/lib/fips_boot/ebin" \
    /experiment/runtime/fips_boot.erl
mv "${install_root}/bin/elixir" "${install_root}/bin/elixir.real"
install -m 0755 /experiment/runtime/elixir "${install_root}/bin/elixir"
install -m 0644 "${elixir_src}/LICENSE" \
    "${install_root}/licenses/elixir-${ELIXIR_VERSION}.txt"
install -m 0644 /build/otp/LICENSE.txt \
    "${install_root}/licenses/erlang-otp-${OTP_VERSION}.txt"

fips_sha256=$(sha256sum "${install_root}/lib/ossl-modules/fips.so" | awk '{print $1}')
cat > "${install_root}/FIPS_BUILD.txt" <<EOF
Mode: OpenSSL FIPS 140-3 validated provider
Certificate: CMVP #4985
OTP: ${OTP_VERSION}
Elixir: ${ELIXIR_VERSION}
OpenSSL core: ${OPENSSL_VERSION} (static in beam.smp)
OpenSSL FIPS provider: ${OPENSSL_FIPS_VERSION} (bundled fips.so)
OpenSSL FIPS provider SHA-256: ${fips_sha256}
Crypto linkage: OTP crypto NIF and OpenSSL core are static in beam.smp
Activation: per-machine fipsinstall -pedantic, OpenSSL fips=yes, OTP fips_mode=true
EOF

find "${install_root}" -type f -name '*.a' -delete
find "${install_root}" -type f -name '*.la' -delete
