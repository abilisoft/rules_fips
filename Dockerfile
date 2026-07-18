ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION} AS build

ARG DEBIAN_FRONTEND=noninteractive
ARG OTP_VERSION=OTP-29.0.3
ARG ELIXIR_VERSION=v1.20.2
ARG OPENSSL_VERSION=openssl-3.5.7
ARG OPENSSL_FIPS_VERSION=openssl-3.1.2

ENV OTP_VERSION=${OTP_VERSION} \
    ELIXIR_VERSION=${ELIXIR_VERSION} \
    OPENSSL_VERSION=${OPENSSL_VERSION} \
    OPENSSL_FIPS_VERSION=${OPENSSL_FIPS_VERSION}

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        build-essential \
        ca-certificates \
        git \
        libncurses-dev \
        m4 \
        perl \
        pkg-config \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth 1 --branch "${OPENSSL_VERSION}" \
        https://github.com/openssl/openssl.git openssl \
    && git clone --depth 1 --branch "${OPENSSL_FIPS_VERSION}" \
        https://github.com/openssl/openssl.git openssl-fips \
    && git clone --depth 1 --branch "${OTP_VERSION}" \
        https://github.com/erlang/otp.git otp \
    && git clone --depth 1 --branch "${ELIXIR_VERSION}" \
        https://github.com/elixir-lang/elixir.git elixir

COPY runtime/openssl-fips.cnf /experiment/runtime/openssl-fips.cnf
COPY scripts/container-openssl.sh /experiment/scripts/container-openssl.sh

RUN bash /experiment/scripts/container-openssl.sh

COPY scripts/container-otp.sh /experiment/scripts/container-otp.sh

RUN bash /experiment/scripts/container-otp.sh

COPY runtime/fips_boot.erl runtime/elixir /experiment/runtime/
COPY scripts/container-elixir.sh /experiment/scripts/container-elixir.sh

RUN bash /experiment/scripts/container-elixir.sh

FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        libncurses6 \
        libstdc++6 \
        libtinfo6 \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/fips-elixir /opt/fips-elixir
COPY runtime/elixir /opt/fips-elixir/bin/elixir
COPY scripts/verify.sh /usr/local/bin/verify-fips

ENV FIPS_ELIXIR_ROOT=/opt/fips-elixir \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/fips-elixir/bin:${PATH}

ENTRYPOINT ["/opt/fips-elixir/bin/elixir"]
CMD ["--version"]
