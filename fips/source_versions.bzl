"""Resolved source identities shared by analysis rules and manifests."""

load("@elixir_src//:rules_fips_source.bzl", _ELIXIR_SOURCE = "SOURCE")
load("@openssl_core_src//:rules_fips_source.bzl", _OPENSSL_CORE_SOURCE = "SOURCE")
load("@openssl_fips_src//:rules_fips_source.bzl", _OPENSSL_FIPS_SOURCE = "SOURCE")
load("@otp_src//:rules_fips_source.bzl", _OTP_SOURCE = "SOURCE")

ELIXIR_SOURCE = _ELIXIR_SOURCE
OPENSSL_CORE_SOURCE = _OPENSSL_CORE_SOURCE
OPENSSL_FIPS_SOURCE = _OPENSSL_FIPS_SOURCE
OTP_SOURCE = _OTP_SOURCE

OPENSSL_FIPS_CERTIFICATE_REFERENCE = (
    "CMVP #4985" if OPENSSL_FIPS_SOURCE.sha256 == "a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539" else "none"
)
