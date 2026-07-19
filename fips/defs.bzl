"""Public API for rules_fips."""

load("//fips:elixir.bzl", _elixir_runtime = "elixir_runtime", _fips_boot_module = "fips_boot_module")
load("//fips:foreign_crypto.bzl", _boringssl_fips_static = "boringssl_fips_static", _openssl_fips = "openssl_fips")
load("//fips:foreign_otp.bzl", _otp_fips_runtime = "otp_fips_runtime", _otp_native_bootstrap = "otp_native_bootstrap")
load("//fips:launcher.bzl", _fips_launcher = "fips_launcher")
load("//fips:package.bzl", _fips_runtime_package = "fips_runtime_package")
load("//fips:providers.bzl", _FipsCryptoInfo = "FipsCryptoInfo", _FipsPlatformInfo = "FipsPlatformInfo", _FipsRuntimeInfo = "FipsRuntimeInfo")

FipsCryptoInfo = _FipsCryptoInfo
FipsPlatformInfo = _FipsPlatformInfo
FipsRuntimeInfo = _FipsRuntimeInfo
boringssl_fips_static = _boringssl_fips_static
openssl_fips = _openssl_fips

def fips_elixir_runtime(
        name,
        crypto,
        backend = "openssl",
        otp_version = "29.0.3",
        elixir_version = "1.20.2",
        visibility = None,
        tags = None):
    """Builds OTP and Elixir in cacheable stages, then audits and packages them."""
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
        backend = backend,
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
        backend = backend,
        bootstrap = ":" + bootstrap_name,
        **common
    )
    _fips_launcher(
        name = launcher_name,
        backend = backend,
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

def fips_elixir_distribution(name, backend = "openssl_fips", visibility = None, tags = None):
    """Builds crypto plus OTP/Elixir as one platform-aware distribution.

    Args:
      name: Name of the distribution target.
      backend: `openssl_fips` or `boringssl_fips_static`.
      visibility: Optional Bazel visibility for the distribution target.
      tags: Optional tags applied to both targets.
    """
    crypto_name = name + "_crypto"
    common = {}
    if tags != None:
        common["tags"] = tags

    if backend == "boringssl_fips_static":
        _boringssl_fips_static(
            name = crypto_name,
            **common
        )
    elif backend == "openssl_fips":
        _openssl_fips(
            name = crypto_name,
            **common
        )
    else:
        fail("unsupported FIPS backend: %s" % backend)

    runtime_args = dict(common)
    if visibility != None:
        runtime_args["visibility"] = visibility
    fips_elixir_runtime(
        name = name,
        backend = "boringssl" if backend == "boringssl_fips_static" else "openssl",
        crypto = ":" + crypto_name,
        **runtime_args
    )
