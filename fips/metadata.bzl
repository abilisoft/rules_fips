"""Small metadata rule used for toolchain and source-pin validation."""

_TOOLCHAIN_TYPE = "//fips:toolchain_type"

def _source_pin_manifest_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    output = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(
        output = output,
        content = """{
  "schema": 1,
  "arch": "%s",
  "boringssl": {
    "certificate": "CMVP #5296",
    "module_name": "BoringCrypto",
    "module_version": "2023042800",
    "commit": "a430310d6563c0734ddafca7731570dfb683dc19",
    "source_repository": "https://boringssl.googlesource.com/boringssl",
    "mirror_archive_sha256": "868930e812afa1967bed57f3cefcadc8a32e1d2207c76b934125189436179346",
    "mirror_archive_url": "https://github.com/google/boringssl/archive/a430310d6563c0734ddafca7731570dfb683dc19.tar.gz"
  },
  "openssl": {
    "certificate": "CMVP #4985",
    "core_version": "3.5.7",
    "provider_version": "3.1.2",
    "core_archive_sha256": "a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8",
    "provider_archive_sha256": "a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539"
  },
  "otp": {
    "version": "29.0.3",
    "archive_sha256": "edef13778a449490bc183134e442a955b134d69c56075d97765d8d4951d8d2bb"
  },
  "elixir": {
    "version": "1.20.2",
    "archive_sha256": "1a25bbf9a9016651fc332eecc02bb9681d0b8e722c2e256e73ddb88fbce6e6b0"
  }
}
""" % platform.arch,
    )
    return [DefaultInfo(files = depset([output]))]

source_pin_manifest = rule(
    implementation = _source_pin_manifest_impl,
    doc = "Writes the exact default source and validation identities.",
    toolchains = [_TOOLCHAIN_TYPE],
)
