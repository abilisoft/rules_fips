#!/bin/sh
set -eu

image=${IMAGE_NAME:-elixir-boringssl-fips:experiment}
platform=${PLATFORM:-}
otp_version=${OTP_VERSION:-OTP-29.0.3}
elixir_version=${ELIXIR_VERSION:-v1.20.2}
boringssl_commit=${BORINGSSL_COMMIT:-a430310d6563c0734ddafca7731570dfb683dc19}
boringssl_cmvp_tarball_sha256=${BORINGSSL_CMVP_TARBALL_SHA256:-2d5339b756dbf1ceb4fdc4b1c8f19e32ded055292dc57827a6592f15ca9d359f}

if [ -n "${platform}" ]; then
    DOCKER_BUILDKIT=1 docker buildx build \
        --progress=plain \
        --platform "${platform}" \
        --load \
        --build-arg OTP_VERSION="${otp_version}" \
        --build-arg ELIXIR_VERSION="${elixir_version}" \
        --build-arg BORINGSSL_COMMIT="${boringssl_commit}" \
        --build-arg BORINGSSL_CMVP_TARBALL_SHA256="${boringssl_cmvp_tarball_sha256}" \
        -f Dockerfile.boringssl \
        -t "${image}" \
        .
else
    DOCKER_BUILDKIT=1 docker build \
        --progress=plain \
        --build-arg OTP_VERSION="${otp_version}" \
        --build-arg ELIXIR_VERSION="${elixir_version}" \
        --build-arg BORINGSSL_COMMIT="${boringssl_commit}" \
        --build-arg BORINGSSL_CMVP_TARBALL_SHA256="${boringssl_cmvp_tarball_sha256}" \
        -f Dockerfile.boringssl \
        -t "${image}" \
        .
fi

echo "built ${image}"
