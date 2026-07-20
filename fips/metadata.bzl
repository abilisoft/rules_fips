"""Machine-readable identities for the source bytes selected by Bzlmod."""

load("@musl_src//:rules_fips_source.bzl", _MUSL_SOURCE = "SOURCE")
load("@openssl_core_src//:rules_fips_source.bzl", _OPENSSL_CORE_SOURCE = "SOURCE")
load("@openssl_fips_src//:rules_fips_source.bzl", _OPENSSL_FIPS_SOURCE = "SOURCE")

def _source_pin_manifest_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".json")
    openssl_certificate = "CMVP #4985" if _OPENSSL_FIPS_SOURCE.sha256 == "a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539" else "none"
    ctx.actions.write(
        output = output,
        content = json.encode_indent({
            "compliance_claim": "none",
            "musl": _source_identity(_MUSL_SOURCE),
            "openssl": {
                "certificate_reference": openssl_certificate,
                "core": _source_identity(_OPENSSL_CORE_SOURCE),
                "provider": _source_identity(_OPENSSL_FIPS_SOURCE),
            },
            "schema": 1,
        }, indent = "  ") + "\n",
    )
    return [DefaultInfo(files = depset([output]))]

def _source_identity(source):
    return {
        "archive_sha256": source.sha256,
        "archive_urls": source.urls,
        "catalog_entry": source.catalog_entry,
        "strip_prefix": source.strip_prefix,
        "version": source.version,
    }

source_pin_manifest = rule(
    implementation = _source_pin_manifest_impl,
    doc = "Writes the exact default source pins and certificate references.",
)
