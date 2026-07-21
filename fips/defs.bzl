"""Public API for rules_fips."""

load("//fips:crypto_sdk.bzl", _fips_crypto_sdk = "fips_crypto_sdk")
load("//fips:foreign_crypto.bzl", _openssl_fips = "openssl_fips")
load("//fips:providers.bzl", _FipsCryptoInfo = "FipsCryptoInfo", _FipsCryptoSdkInfo = "FipsCryptoSdkInfo", _FipsPlatformInfo = "FipsPlatformInfo")
load("//fips:rust_adapter.bzl", _fips_rust_toolchain = "fips_rust_toolchain")

FipsCryptoInfo = _FipsCryptoInfo
FipsCryptoSdkInfo = _FipsCryptoSdkInfo
FipsPlatformInfo = _FipsPlatformInfo
openssl_fips = _openssl_fips
fips_crypto_sdk = _fips_crypto_sdk
fips_rust_toolchain = _fips_rust_toolchain

def openssl_fips_sdk(name, visibility = None, tags = None):
    """Builds OpenSSL FIPS and exports its normalized consumer SDK.

    Args:
      name: SDK target name.
      visibility: Optional visibility for the exported SDK targets.
      tags: Optional tags applied to generated targets.

    Returns:
      A struct whose `otp_crypto_sdk` field can be expanded directly into
      rules_elixir_mix's backend-neutral `otp_crypto_sdk` rule.
    """
    crypto_name = name + "_crypto"
    common = {}
    if tags != None:
        common["tags"] = tags
    _openssl_fips(
        name = crypto_name,
        **common
    )
    return _fips_crypto_sdk(
        name = name,
        crypto = ":" + crypto_name,
        visibility = visibility,
        **common
    )
