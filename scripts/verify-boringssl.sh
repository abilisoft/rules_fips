#!/bin/sh
set -eu

fips_root=${FIPS_ELIXIR_ROOT:-/opt/fips-elixir}
beam=$(find "${fips_root}/lib/erlang/erts-"* -type f -name beam.smp -print -quit)
checker=${fips_root}/bin/boring-fips-check

if [ -z "${beam}" ]; then
    echo "beam.smp not found" >&2
    exit 1
fi

echo "==> Native dependency check"
if ldd "${beam}" | grep -E 'lib(crypto|ssl)\.so'; then
    echo "beam.smp unexpectedly depends on a shared crypto library" >&2
    exit 1
fi
if ldd "${checker}" | grep -E 'lib(crypto|ssl)\.so'; then
    echo "BoringCrypto checker unexpectedly depends on a shared crypto library" >&2
    exit 1
fi
ldd "${beam}"

echo "==> Exact BoringCrypto identity and service-indicator check"
expected_sha=$(sed -n 's/^BoringCrypto checker SHA-256: //p' "${fips_root}/FIPS_BUILD.txt")
actual_sha=$(sha256sum "${checker}" | awk '{print $1}')
if [ -z "${expected_sha}" ] || [ "${actual_sha}" != "${expected_sha}" ]; then
    echo "BoringCrypto checker hash mismatch" >&2
    exit 1
fi
"${checker}"

echo "==> Elixir/OTP BoringCrypto runtime check"
"${fips_root}/bin/elixir" -e '
info = :crypto.info()

unless :crypto.info_fips() == :enabled,
  do: raise("FIPS is not enabled")
unless info[:link_type] == :static,
  do: raise("OTP crypto is not statically linked")
unless String.contains?(List.to_string(info[:cryptolib_version_compiled]), "BoringSSL"),
  do: raise("OTP was not compiled against BoringSSL")
unless String.contains?(List.to_string(info[:cryptolib_version_linked]), "BoringSSL"),
  do: raise("OTP is not linked to BoringSSL")

unless :crypto.hash(:sha256, "abc") ==
         <<186, 120, 22, 191, 143, 1, 207, 234, 65, 65, 64, 222, 93, 174,
           34, 35, 176, 3, 97, 163, 150, 23, 122, 156, 180, 16, 255, 97, 242,
           0, 21, 173>>,
  do: raise("SHA-256 KAT failed")

md5_blocked =
  try do
    :crypto.hash(:md5, "must fail")
    false
  rescue
    ErlangError -> true
  end

unless md5_blocked, do: raise("OTP exposed MD5 while FIPS mode was enabled")
unless :crypto.enable_fips_mode(false) == false,
  do: raise("BoringCrypto unexpectedly allowed FIPS mode to be disabled")
unless :crypto.info_fips() == :enabled,
  do: raise("FIPS mode changed after the disable attempt")

IO.inspect(info, label: "crypto_info")
IO.puts("ELIXIR_BORINGCRYPTO_FIPS_VERIFIED")
'

echo "STATIC_BORINGCRYPTO_FIPS_EXPERIMENT_VERIFIED"
