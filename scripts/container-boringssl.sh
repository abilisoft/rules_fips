#!/usr/bin/env bash
set -Eeuo pipefail

jobs="${BUILD_JOBS:-$(nproc)}"
source_root=/build/boringssl
build_root=${source_root}/build
install_root=/opt/fips-elixir

echo "==> Building exact validated BoringCrypto ${BORINGSSL_COMMIT}"
cmake -S "${source_root}" -B "${build_root}" -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DFIPS=1
cmake --build "${build_root}" --parallel "${jobs}"

if [[ -n "${BORINGSSL_BUILD_ARCH:-}" \
      && -n "${BORINGSSL_TARGET_ARCH:-}" \
      && "${BORINGSSL_BUILD_ARCH}" != "${BORINGSSL_TARGET_ARCH}" ]]; then
    echo "==> Running BoringSSL tests under emulation"
    echo "==> Skipping only crypto/urandom_test (QEMU user-mode lacks ptrace)"

    test_manifest=${source_root}/util/all_tests.json
    full_test_manifest=${source_root}/util/all_tests.json.full
    filtered_test_manifest=${source_root}/util/all_tests.json.emulated

    cp "${test_manifest}" "${full_test_manifest}"
    python3 -c '
import json
import sys

tests = json.load(sys.stdin)
filtered = [test for test in tests if test["cmd"][0] != "crypto/urandom_test"]
json.dump(filtered, sys.stdout, indent=2)
print()
' <"${full_test_manifest}" >"${filtered_test_manifest}"
    mv "${filtered_test_manifest}" "${test_manifest}"

    (
        cd "${source_root}"
        go test \
            ./ssl/test/runner/hpke \
            ./util/ar \
            ./util/fipstools/acvp/acvptool/testmodulewrapper \
            ./util/fipstools/delocate
        go run util/all_tests.go -build-dir "${build_root}"
        (
            cd ssl/test/runner
            go test \
                -timeout=30m \
                -shim-path "${build_root}/ssl/test/bssl_shim" \
                -handshaker-path "${build_root}/ssl/test/handshaker"
        )
    )

    mv "${full_test_manifest}" "${test_manifest}"
else
    cmake --build "${build_root}" --target run_tests --parallel "${jobs}"
fi

install -d "${install_root}/bin" "${install_root}/include" \
    "${install_root}/lib" "${install_root}/licenses"
cp -R "${source_root}/include/openssl" "${install_root}/include/"
install -m 0644 "${build_root}/crypto/libcrypto.a" "${install_root}/lib/libcrypto.a"
install -m 0644 "${build_root}/ssl/libssl.a" "${install_root}/lib/libssl.a"
install -m 0644 "${source_root}/LICENSE" \
    "${install_root}/licenses/boringssl-${BORINGSSL_COMMIT}.txt"

clang -O2 -I"${install_root}/include" \
    /experiment/runtime/boring_fips_check.c \
    "${install_root}/lib/libcrypto.a" -pthread -ldl \
    -o "${install_root}/bin/boring-fips-check"

echo "==> Verifying BoringCrypto module identity, integrity, and service indicator"
"${install_root}/bin/boring-fips-check"
