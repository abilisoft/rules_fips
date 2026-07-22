"""Public API for rules_fips."""

load("//fips:crypto_sdk.bzl", _fips_crypto_sdk = "fips_crypto_sdk")
load("//fips:foreign_crypto.bzl", _openssl_fips = "openssl_fips")
load("//fips:pkg_config.bzl", _target_pkg_config_sdk = "target_pkg_config_sdk")
load(
    "//fips:providers.bzl",
    _FipsCryptoInfo = "FipsCryptoInfo",
    _FipsCryptoSdkInfo = "FipsCryptoSdkInfo",
    _FipsPlatformInfo = "FipsPlatformInfo",
    _TargetPkgConfigSdkInfo = "TargetPkgConfigSdkInfo",
)
load("//fips:rust_adapter.bzl", _fips_rust_toolchain = "fips_rust_toolchain")
load(
    "//fips/toolchains:runtime_tool.bzl",
    _hermetic_target_runtime_test = "hermetic_target_runtime_test",
    _hermetic_target_runtime_tool = "hermetic_target_runtime_tool",
)

FipsCryptoInfo = _FipsCryptoInfo
FipsCryptoSdkInfo = _FipsCryptoSdkInfo
FipsPlatformInfo = _FipsPlatformInfo
TargetPkgConfigSdkInfo = _TargetPkgConfigSdkInfo
openssl_fips = _openssl_fips
fips_crypto_sdk = _fips_crypto_sdk
fips_rust_toolchain = _fips_rust_toolchain
hermetic_target_runtime_test = _hermetic_target_runtime_test
hermetic_target_runtime_tool = _hermetic_target_runtime_tool
target_pkg_config_sdk = _target_pkg_config_sdk

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
