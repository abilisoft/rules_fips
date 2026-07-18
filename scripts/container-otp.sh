#!/usr/bin/env bash
set -Eeuo pipefail

jobs="${BUILD_JOBS:-$(nproc)}"
install_root=/opt/fips-elixir
otp_src=/build/otp
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

echo "==> Building unmodified OTP with static crypto NIF and OpenSSL core"
static_openssl_libs="-Wl,--start-group ${install_root}/lib/libssl.a ${install_root}/lib/libcrypto.a -Wl,--end-group -ldl -pthread -lm"
(
    cd "${otp_src}"
    LIBS="${static_openssl_libs}" ./configure \
        --prefix="${install_root}" \
        --with-ssl="${install_root}" \
        --with-ssl-lib-subdir=lib \
        --disable-dynamic-ssl-lib \
        --enable-fips \
        --enable-static-nifs \
        --disable-pie \
        --without-javac \
        --without-wx \
        --without-debugger \
        --without-observer \
        --without-et \
        --without-odbc
    # OTP's parallel emulator targets can otherwise race while creating the
    # same static NIF archives. Build those shared prerequisites once first.
    make -C lib ERL_TOP="${otp_src}" BUILD_STATIC_LIBS=1 TYPE=opt static_lib
    make -j"${jobs}"
)

echo "==> Verifying OTP FIPS mode before installation"
(
    cd "${otp_src}"
    ./bin/erl -crypto fips_mode true -noshell -eval '
        {ok, _} = application:ensure_all_started(crypto),
        enabled = crypto:info_fips(),
        #{link_type := static,
          fips_provider_available := true,
          fips_provider_buildinfo := BuildInfo} = crypto:info(),
        true = string:find(BuildInfo, "3.1.2") =/= nomatch,
        <<227,176,196,66,152,252,28,20,154,251,244,200,153,111,185,36,
          39,174,65,228,100,155,147,76,164,149,153,27,120,82,184,85>> =
            crypto:hash(sha256, <<>>),
        io:format("OTP_OPENSSL_FIPS_VERIFIED ~tp~n", [crypto:info()]),
        halt(0).'
    make install
)
