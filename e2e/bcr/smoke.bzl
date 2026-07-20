"""Analysis-only BCR consumer smoke test."""

load(
    "@rules_fips//fips:defs.bzl",
    "FipsCryptoInfo",
    "FipsPlatformInfo",
    "FipsRuntimeInfo",
    "fips_elixir_distribution",
    "fips_elixir_runtime",
    "openssl_fips",
)

_PUBLIC_API = (
    FipsCryptoInfo,
    FipsPlatformInfo,
    FipsRuntimeInfo,
    fips_elixir_distribution,
    fips_elixir_runtime,
    openssl_fips,
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
