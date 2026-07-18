#!/bin/sh
set -eu

image=${IMAGE_NAME:-elixir-openssl-fips:experiment}
platform=${PLATFORM:-}
otp_version=${OTP_VERSION:-OTP-29.0.3}
elixir_version=${ELIXIR_VERSION:-v1.20.2}
openssl_version=${OPENSSL_VERSION:-openssl-3.5.7}
openssl_fips_version=${OPENSSL_FIPS_VERSION:-openssl-3.1.2}

if [ -n "${platform}" ]; then
    DOCKER_BUILDKIT=1 docker buildx build \
        --progress=plain \
        --platform "${platform}" \
        --load \
        --build-arg OTP_VERSION="${otp_version}" \
        --build-arg ELIXIR_VERSION="${elixir_version}" \
        --build-arg OPENSSL_VERSION="${openssl_version}" \
        --build-arg OPENSSL_FIPS_VERSION="${openssl_fips_version}" \
        -t "${image}" \
        .
else
    DOCKER_BUILDKIT=1 docker build \
        --progress=plain \
        --build-arg OTP_VERSION="${otp_version}" \
        --build-arg ELIXIR_VERSION="${elixir_version}" \
        --build-arg OPENSSL_VERSION="${openssl_version}" \
        --build-arg OPENSSL_FIPS_VERSION="${openssl_fips_version}" \
        -t "${image}" \
        .
fi

echo "built ${image}"
