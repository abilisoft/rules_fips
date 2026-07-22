"""Analysis-only BCR consumer smoke test."""

load(
    "@rules_fips//fips:defs.bzl",
    "FipsCryptoInfo",
    "FipsCryptoSdkInfo",
    "FipsPlatformInfo",
    "fips_crypto_sdk",
    "fips_rust_toolchain",
    "openssl_fips",
    "openssl_fips_sdk",
)

_PUBLIC_API = (
    FipsCryptoInfo,
    FipsCryptoSdkInfo,
    FipsPlatformInfo,
    fips_crypto_sdk,
    fips_rust_toolchain,
    openssl_fips,
    openssl_fips_sdk,
)

def _rules_fips_smoke_impl(ctx):
    if len(_PUBLIC_API) != 7:
        fail("rules_fips public API is incomplete")
    output = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(output, "rules_fips public API resolved\n")
    return [DefaultInfo(files = depset([output]))]

rules_fips_smoke = rule(
    implementation = _rules_fips_smoke_impl,
)

def _fake_rust_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            all_files = ctx.attr.files[DefaultInfo].files,
            env = {},
            extra_rustc_flags_for_crate_types = {},
        ),
        platform_common.TemplateVariableInfo({}),
    ]

fake_rust_toolchain = rule(
    implementation = _fake_rust_toolchain_impl,
    attrs = {
        "files": attr.label(mandatory = True),
    },
)
