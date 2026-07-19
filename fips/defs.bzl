"""Public API for rules_fips."""

load("//fips:elixir.bzl", _elixir_runtime = "elixir_runtime", _fips_boot_module = "fips_boot_module")
load("//fips:foreign_crypto.bzl", _openssl_fips = "openssl_fips")
load("//fips:foreign_otp.bzl", _otp_fips_runtime = "otp_fips_runtime", _otp_native_bootstrap = "otp_native_bootstrap")
load("//fips:launcher.bzl", _fips_launcher = "fips_launcher")
load("//fips:package.bzl", _fips_runtime_package = "fips_runtime_package")
load("//fips:providers.bzl", _FipsCryptoInfo = "FipsCryptoInfo", _FipsPlatformInfo = "FipsPlatformInfo", _FipsRuntimeInfo = "FipsRuntimeInfo")
load("//fips:source_versions.bzl", "ELIXIR_SOURCE", "OTP_SOURCE")

FipsCryptoInfo = _FipsCryptoInfo
FipsPlatformInfo = _FipsPlatformInfo
FipsRuntimeInfo = _FipsRuntimeInfo
openssl_fips = _openssl_fips

def fips_elixir_runtime(
        name,
        crypto,
        otp_version = OTP_SOURCE.version,
        elixir_version = ELIXIR_SOURCE.version,
        visibility = None,
        tags = None):
    """Builds OTP and Elixir in cacheable stages, then audits and packages them.

    Args:
      name: Distribution target name.
      crypto: Label providing `FipsCryptoInfo`.
      otp_version: OTP version recorded in evidence.
      elixir_version: Elixir version recorded in evidence.
      visibility: Optional visibility for the distribution target.
      tags: Optional tags applied to generated targets.
    """
    common = {}
    if tags != None:
        common["tags"] = tags
    bootstrap_name = name + "_otp_bootstrap"
    otp_name = name + "_otp"
    elixir_name = name + "_elixir"
    boot_name = name + "_fips_boot"
    launcher_name = name + "_launcher"

    _otp_native_bootstrap(
        name = bootstrap_name,
        otp_version = otp_version,
        **common
    )
    _otp_fips_runtime(
        name = otp_name,
        bootstrap = ":" + bootstrap_name,
        crypto = crypto,
        otp_version = otp_version,
        **common
    )
    _elixir_runtime(
        name = elixir_name,
        bootstrap = ":" + bootstrap_name,
        elixir_version = elixir_version,
        otp = ":" + otp_name,
        **common
    )
    _fips_boot_module(
        name = boot_name,
        bootstrap = ":" + bootstrap_name,
        **common
    )
    _fips_launcher(
        name = launcher_name,
        elixir_version = elixir_version,
        **common
    )
    package_args = dict(common)
    if visibility != None:
        package_args["visibility"] = visibility
    _fips_runtime_package(
        name = name,
        boot_beam = ":" + boot_name,
        crypto = crypto,
        elixir = ":" + elixir_name,
        launcher = ":" + launcher_name,
        otp = ":" + otp_name,
        **package_args
    )

def fips_elixir_distribution(name, visibility = None, tags = None):
    """Builds OpenSSL plus OTP/Elixir as one platform-aware distribution.

    Args:
      name: Name of the distribution target.
      visibility: Optional Bazel visibility for the distribution target.
      tags: Optional tags applied to both targets.
    """
    crypto_name = name + "_crypto"
    common = {}
    if tags != None:
        common["tags"] = tags

    _openssl_fips(
        name = crypto_name,
        **common
    )

    runtime_args = dict(common)
    if visibility != None:
        runtime_args["visibility"] = visibility
    fips_elixir_runtime(
        name = name,
        crypto = ":" + crypto_name,
        **runtime_args
    )
