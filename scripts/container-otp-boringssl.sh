#!/usr/bin/env bash
set -Eeuo pipefail

jobs="${BUILD_JOBS:-$(nproc)}"
install_root=/opt/fips-elixir
otp_src=/build/otp

echo "==> Building unmodified OTP with static BoringCrypto"
static_boringssl_libs="-Wl,--start-group ${install_root}/lib/libssl.a ${install_root}/lib/libcrypto.a -Wl,--end-group -ldl -pthread -lm"
(
    cd "${otp_src}"
    CC=clang CXX=clang++ \
    CPPFLAGS="-I/experiment/compat/boringssl" \
    LIBS="${static_boringssl_libs}" ./configure \
        --prefix="${install_root}" \
        --with-ssl="${install_root}" \
        --with-ssl-lib-subdir=lib \
        --disable-dynamic-ssl-lib \
        --disable-evp-dh \
        --disable-evp-hmac \
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
          cryptolib_version_linked := Linked} = crypto:info(),
        true = string:find(Linked, "BoringSSL") =/= nomatch,
        false = crypto:enable_fips_mode(false),
        enabled = crypto:info_fips(),
        <<227,176,196,66,152,252,28,20,154,251,244,200,153,111,185,36,
          39,174,65,228,100,155,147,76,164,149,153,27,120,82,184,85>> =
            crypto:hash(sha256, <<>>),
        io:format("OTP_BORINGCRYPTO_FIPS_VERIFIED ~tp~n", [crypto:info()]),
        halt(0).'
    make install
)
