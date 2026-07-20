"""Analysis-only BCR consumer smoke test."""

load(
    "@rules_fips//fips:defs.bzl",
    "FipsCryptoInfo",
    "FipsCryptoSdkInfo",
    "FipsPlatformInfo",
    "fips_crypto_sdk",
    "openssl_fips",
    "openssl_fips_sdk",
)

_PUBLIC_API = (
    FipsCryptoInfo,
    FipsCryptoSdkInfo,
    FipsPlatformInfo,
    fips_crypto_sdk,
    openssl_fips,
    openssl_fips_sdk,
)

def _rules_fips_smoke_impl(ctx):
    if len(_PUBLIC_API) != 6:
        fail("rules_fips public API is incomplete")
    output = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(output, "rules_fips public API resolved\n")
    return [DefaultInfo(files = depset([output]))]

rules_fips_smoke = rule(
    implementation = _rules_fips_smoke_impl,
)
