#!/usr/bin/env bash
set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

jobs="${BUILD_JOBS:-$(nproc)}"
install_root=/opt/fips-elixir
elixir_src=/build/elixir

echo "==> Building Elixir against the BoringCrypto OTP"
(
    cd "${elixir_src}"
    PATH="${install_root}/bin:${PATH}" make -j"${jobs}"
    PATH="${install_root}/bin:${PATH}" make install PREFIX="${install_root}"
)

echo "==> Installing BoringCrypto FIPS-on Elixir launcher"
mkdir -p "${install_root}/lib/fips_boot/ebin"
"${install_root}/bin/erlc" \
    -o "${install_root}/lib/fips_boot/ebin" \
    /experiment/runtime/fips_boot_boringssl.erl
mv "${install_root}/bin/elixir" "${install_root}/bin/elixir.real"
install -m 0755 /experiment/runtime/elixir-boringssl "${install_root}/bin/elixir"
install -m 0644 "${elixir_src}/LICENSE" \
    "${install_root}/licenses/elixir-${ELIXIR_VERSION}.txt"
install -m 0644 /build/otp/LICENSE.txt \
    "${install_root}/licenses/erlang-otp-${OTP_VERSION}.txt"

beam=$(find "${install_root}/lib/erlang/erts-"* -type f -name beam.smp -print -quit)
beam_sha256=$(sha256sum "${beam}" | awk '{print $1}')
checker_sha256=$(sha256sum "${install_root}/bin/boring-fips-check" | awk '{print $1}')
cat > "${install_root}/FIPS_BUILD.txt" <<EOF
Mode: BoringCrypto FIPS 140-3 validated module
Certificate: CMVP #5296
OTP: ${OTP_VERSION}
Elixir: ${ELIXIR_VERSION}
BoringCrypto module version: 2023042800
BoringSSL source commit: ${BORINGSSL_COMMIT}
CMVP source tarball SHA-256: ${BORINGSSL_CMVP_TARBALL_SHA256}
Installed BEAM SHA-256: ${beam_sha256}
BoringCrypto checker SHA-256: ${checker_sha256}
Crypto linkage: OTP crypto NIF and BoringCrypto are static in beam.smp
Activation: BoringCrypto FIPS build; FIPS_mode cannot be disabled
Approval boundary: per-service indication, as required by CMVP #5296
EOF

find "${install_root}" -type f -name '*.a' -delete
find "${install_root}" -type f -name '*.la' -delete
