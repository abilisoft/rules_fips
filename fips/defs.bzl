"""Public API for rules_fips."""

load("//fips:compiler_rt.bzl", _compiler_rt_builtins = "compiler_rt_builtins")
load("//fips:crypto.bzl", _boringcrypto_fips = "boringcrypto_fips", _openssl_fips = "openssl_fips")
load("//fips:providers.bzl", _FipsCryptoInfo = "FipsCryptoInfo", _FipsPlatformInfo = "FipsPlatformInfo", _FipsRuntimeInfo = "FipsRuntimeInfo")
load("//fips:runtime.bzl", _fips_elixir_runtime = "fips_elixir_runtime")

FipsCryptoInfo = _FipsCryptoInfo
FipsPlatformInfo = _FipsPlatformInfo
FipsRuntimeInfo = _FipsRuntimeInfo
boringcrypto_fips = _boringcrypto_fips
compiler_rt_builtins = _compiler_rt_builtins
openssl_fips = _openssl_fips
fips_elixir_runtime = _fips_elixir_runtime

def fips_elixir_distribution(name, backend = "boringcrypto", visibility = None, tags = None):
    """Builds crypto plus OTP/Elixir as one platform-aware distribution.

    Args:
      name: Name of the distribution target.
      backend: `boringcrypto` or `openssl`.
      visibility: Optional Bazel visibility for the distribution target.
      tags: Optional tags applied to both targets.
    """
    crypto_name = name + "_crypto"
    common = {}
    if tags != None:
        common["tags"] = tags

    if backend == "boringcrypto":
        _boringcrypto_fips(
            name = crypto_name,
            **common
        )
    elif backend == "openssl":
        _openssl_fips(
            name = crypto_name,
            **common
        )
    else:
        fail("unsupported FIPS backend: %s" % backend)

    runtime_args = dict(common)
    if visibility != None:
        runtime_args["visibility"] = visibility
    _fips_elixir_runtime(
        name = name,
        crypto = ":" + crypto_name,
        **runtime_args
    )
