# Selecting versions

`rules_fips` separates convenience from reproducibility:

- the catalog stores combinations maintained and exercised by this project;
- exact source overrides let a root module try releases outside that matrix.

Neither path uses a floating branch, tag alias, or `latest` URL.

## Pinned build environment

The OpenSSL catalog controls application-facing crypto source selections.
Execution tools and target sysroots are separate internal pins in
`MODULE.bazel` and `fips/extensions.bzl`:

| Input | Current pin |
| --- | --- |
| Bazel | 9.2.0 |
| Clang and LLD execution tools | 22.1.8 |
| Target LLVM headers, libc++, unwind, and compiler-rt | 22.1.3 |
| musl target runtime | 1.2.6-r2 |
| Go tool compiler | 1.26.5 |
| GNU make | 4.4.1-r4 |
| BusyBox | 1.37.0-r31 |
| Perl | 5.40.1 via `rules_perl` 1.1.2 |
| Arm64 user-mode emulator | QEMU 11.0.2-r1 |

These are integrity-pinned build inputs, not public catalog choices. Updating
one still requires both target platforms to pass because it can change output
bytes or the meaning of build-time checks.

## Tested catalog

The default is the newest combination currently tested by this repository.
Selecting it explicitly is optional:

```starlark
fips_sources = use_extension(
    "@rules_fips//fips:extensions.bzl",
    "fips_sources",
)

fips_sources.openssl(
    core_version = "3.5.7",
    fips_provider_version = "3.1.2",
)
```

Available entries live in `fips/versions.bzl`. A version belongs in that file
only after the repository's affected platform matrix passes. “Catalog entry”
means tested here; it does not mean FIPS validated or suitable for a particular
deployment.

## Exact custom source

Only the root module may override a pin. Supply the complete source identity:

```starlark
fips_sources.source(
    name = "openssl_core_src",
    version = "3.x.y",
    urls = [
        "https://mirror.example.invalid/openssl-3.x.y.tar.gz",
        "https://upstream.example.invalid/openssl-3.x.y.tar.gz",
    ],
    sha256 = "<64 hexadecimal characters>",
    strip_prefix = "openssl-3.x.y",
)
```

The same form accepts `name = "openssl_fips_src"` for a provider override.
Core and provider may be overridden independently. Do not combine an OpenSSL
catalog tag with either OpenSSL source override; the extension rejects that
ambiguous configuration.

The checksum is mandatory because URLs are locations, not identities. Mirrors
are safe only when every URL is expected to return the same pinned bytes.

## What custom means

The build does not reject a custom release merely because it is absent from
the catalog. It still applies the same build graph and runtime checks. The
resolved source manifest marks that input with:

```json
{
  "catalog_entry": false
}
```

That is an explicit maintenance boundary:

- API and build compatibility have not been established by the project matrix;
- a custom FIPS-provider source does not inherit a certificate reference from
  its version string;
- a successful build remains evidence, not a compliance result.

The known certificate reference is derived conservatively from the exact
provider archive hash. An unknown provider archive is recorded with no
certificate reference until maintainers review authoritative CMVP material.

## Inspect before compiling

```console
bazel build --config=local //fips:source_pins
```

The resulting JSON shows the resolved URL list, SHA-256, strip prefix, version,
catalog status, and provider certificate reference. Review it before spending
time on an OTP/Elixir build.
