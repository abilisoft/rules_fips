#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=${RULES_FIPS_BUILD_IMAGE:-docker.io/library/python:3.14.5-trixie@sha256:11591407222400cafc1b2bd03fe09a90988f091fc9ddff4a901f80ceb02b78b3}

case "$(uname -m)" in
    x86_64 | amd64) execution_platform=linux/amd64 ;;
    aarch64 | arm64) execution_platform=linux/arm64 ;;
    *)
        echo "unsupported execution architecture: $(uname -m)" >&2
        exit 2
        ;;
esac

if [ "$#" -eq 0 ]; then
    set -- \
        build \
        --config=linux_amd64 \
        //examples:elixir_boringcrypto_fips
fi

exec docker run --rm \
    --platform "${execution_platform}" \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp/rules-fips-home \
    --volume "${repo_dir}:/workspace" \
    --workdir /workspace \
    "${image}" \
    /bin/sh -ceu '
        bazel_version=9.2.0
        case "$(uname -m)" in
            x86_64)
                bazel_arch=x86_64
                bazel_sha=7668a95db1250f12c40407251e4e203b4ec8bf39bc495d2f485b2d8c99048694
                ;;
            aarch64)
                bazel_arch=arm64
                bazel_sha=049dd21f40ad979db11c3ee68c96a42ce75f1185e69ac61ab20de1501427a410
                ;;
            *)
                echo "unsupported container architecture: $(uname -m)" >&2
                exit 2
                ;;
        esac

        bazel_dir=/workspace/.local/hermetic-bazel
        bazel_bin=${bazel_dir}/bazel-${bazel_version}-linux-${bazel_arch}
        mkdir -p "${HOME}" "${bazel_dir}"
        if ! printf "%s  %s\n" "${bazel_sha}" "${bazel_bin}" | sha256sum -c - >/dev/null 2>&1; then
            tmp=${bazel_bin}.download
            BAZEL_URL="https://github.com/bazelbuild/bazel/releases/download/${bazel_version}/bazel-${bazel_version}-linux-${bazel_arch}" \
            BAZEL_DEST="${tmp}" \
            python3 -c "import os, urllib.request; urllib.request.urlretrieve(os.environ[\"BAZEL_URL\"], os.environ[\"BAZEL_DEST\"])"
            printf "%s  %s\n" "${bazel_sha}" "${tmp}" | sha256sum -c -
            chmod 0755 "${tmp}"
            mv "${tmp}" "${bazel_bin}"
        fi

        bazel_command=$1
        shift
        exec "${bazel_bin}" \
            --output_user_root=/workspace/.local/bazel-output-hermetic \
            "${bazel_command}" \
            --repo_contents_cache= \
            "$@"
    ' rules-fips "$@"
