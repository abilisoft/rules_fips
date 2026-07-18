#!/bin/sh
set -eu

fips_root=${FIPS_ELIXIR_ROOT:-/opt/fips-elixir}
beam=$(find "${fips_root}/lib/erlang/erts-"* -type f -name beam.smp -print -quit)
fips_module=${fips_root}/lib/ossl-modules/fips.so

if [ -z "${beam}" ]; then
    echo "beam.smp not found" >&2
    exit 1
fi

echo "==> Native dependency check"
if ldd "${beam}" | grep -E 'lib(crypto|ssl)\.so'; then
    echo "beam.smp unexpectedly depends on a shared OpenSSL library" >&2
    exit 1
fi
if ldd "${fips_root}/bin/openssl" | grep -E 'lib(crypto|ssl)\.so'; then
    echo "openssl unexpectedly depends on a shared OpenSSL library" >&2
    exit 1
fi
if ldd "${fips_module}" | grep -E 'lib(crypto|ssl)\.so'; then
    echo "fips.so unexpectedly depends on a shared OpenSSL library" >&2
    exit 1
fi
ldd "${beam}"

echo "==> FIPS module identity check"
expected_sha=$(sed -n 's/^OpenSSL FIPS provider SHA-256: //p' "${fips_root}/FIPS_BUILD.txt")
actual_sha=$(sha256sum "${fips_module}" | awk '{print $1}')
if [ -z "${expected_sha}" ] || [ "${actual_sha}" != "${expected_sha}" ]; then
    echo "bundled FIPS provider hash mismatch" >&2
    exit 1
fi

echo "==> Elixir/OTP FIPS runtime check"
"${fips_root}/bin/elixir" -e '
info = :crypto.info()

unless :crypto.info_fips() == :enabled,
  do: raise("FIPS is not enabled")
unless info[:link_type] == :static,
  do: raise("OTP crypto is not statically linked")
unless info[:fips_provider_available] == true,
  do: raise("OpenSSL FIPS provider is unavailable")
unless String.contains?(List.to_string(info[:fips_provider_buildinfo]), "3.1.2"),
  do: raise("unexpected OpenSSL FIPS provider")

unless :crypto.hash(:sha256, "abc") ==
         <<186, 120, 22, 191, 143, 1, 207, 234, 65, 65, 64, 222, 93, 174,
           34, 35, 176, 3, 97, 163, 150, 23, 122, 156, 180, 16, 255, 97, 242,
           0, 21, 173>>,
  do: raise("SHA-256 KAT failed")

md5_blocked = fn ->
  try do
    :crypto.hash(:md5, "must fail")
    false
  rescue
    ErlangError -> true
  end
end

unless md5_blocked.(), do: raise("MD5 was not blocked")
unless :crypto.enable_fips_mode(false) == true,
  do: raise("OTP FIPS status toggle was unavailable")
unless md5_blocked.(),
  do: raise("OpenSSL provider policy allowed MD5 after the OTP status toggle")
unless :crypto.enable_fips_mode(true) == true and
         :crypto.info_fips() == :enabled,
  do: raise("FIPS mode could not be restored")

IO.inspect(info, label: "crypto_info")
IO.puts("ELIXIR_OPENSSL_FIPS_VERIFIED")
'

echo "STATIC_OPENSSL_FIPS_EXPERIMENT_VERIFIED"
