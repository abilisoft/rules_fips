# rules_fips

[![CI](https://github.com/abilisoft/rules_fips/actions/workflows/ci.yml/badge.svg)](https://github.com/abilisoft/rules_fips/actions/workflows/ci.yml)
[![CodeQL](https://github.com/abilisoft/rules_fips/actions/workflows/codeql.yml/badge.svg)](https://github.com/abilisoft/rules_fips/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/abilisoft/rules_fips/badge)](https://securityscorecards.dev/viewer/?uri=github.com/abilisoft/rules_fips)
[![License](https://img.shields.io/github/license/abilisoft/rules_fips)](LICENSE)

Hermetic Bazel rules for building a normalized OpenSSL FIPS crypto SDK. The SDK
contains static archives and headers for consumers, plus the provider, config,
musl runtime, and shell-free activation/launch tools needed at deployment.

> [!IMPORTANT]
> The project records build and provider evidence. It does not certify,
> validate, approve, or guarantee the FIPS compliance of an application or
> deployment.

> [!NOTE]
> `rules_fips` does not build OTP, Elixir, Python, Rust, or application
> releases. Language rule sets consume its backend-neutral SDK contract.

## What it produces

`openssl_fips_sdk` exposes a target-specific SDK directory and an explicit
deployment payload. A consumer receives:

- `include/`, `lib/libcrypto.a`, and `lib/libssl.a` for its build;
- `fips.so`, `openssl.cnf`, OpenSSL, the musl loader/libc, and license/evidence
  files for deployment;
- a native activation tool and a native runtime-loader wrapper; and
- opaque argument/environment templates. Consumers do not branch on backend
  identity.

The current tested catalog selects:

| Component | Selection |
| --- | --- |
| OpenSSL core | 3.5.7 LTS |
| OpenSSL FIPS provider | 3.1.2, referencing CMVP certificate #4985 |
| Targets | Linux AMD64 and Linux Arm64 |
| C library | musl |
| Build compiler | Clang/LLD 22.1.8 |
| Arm64 validation | static QEMU 11.0.2, build-time only |

The current public backend is OpenSSL. wolfSSL is not implemented or claimed by
this release.

## Build it

Build the AMD64 SDK:

```console
bazel build --config=local --config=linux_amd64 \
  //examples:openssl_fips_sdk
```

Build the Arm64 SDK. Provider checks run through pinned QEMU when the execution
host is AMD64; that is emulated target execution, not native hardware evidence:

```console
bazel build --config=local --config=linux_arm64 \
  //examples:openssl_fips_sdk
```

OpenSSL 3 loads its FIPS provider dynamically. `fully_static` is therefore
false even though the consumer can link the OpenSSL core statically. The SDK
makes that runtime boundary explicit instead of silently borrowing a host
provider or configuration.

## Use the rules

```starlark
load("@rules_fips//fips:defs.bzl", "openssl_fips_sdk")

openssl_fips_sdk(
    name = "crypto_sdk",
)
```

The catalog is the easy path. A root module may select any tested pair:

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

Need a version that is not in the matrix? Override either source with exact,
immutable input identity:

```starlark
fips_sources.source(
    name = "openssl_core_src",
    version = "3.x.y",
    urls = ["https://example.invalid/openssl-3.x.y.tar.gz"],
    sha256 = "<64 hexadecimal characters>",
    strip_prefix = "openssl-3.x.y",
)
```

Catalog entries carry their own checksums. A custom URL requires SHA-256 so a
declared build cannot silently fetch different bytes. Custom selections appear
as `"catalog_entry": false` in the source manifest and are not represented as
tested by this project.

Build the source manifest alone to inspect resolved versions without compiling
OpenSSL:

```console
bazel build --config=local //fips:source_pins
```

## Consumer boundary

The returned `otp_crypto_sdk` dictionary is a convenience adapter for
`rules_elixir_mix`; it is data, not a shared provider dependency. rules_fips
owns OpenSSL source, build identity, certificate metadata, provider activation,
and SDK runtime payload. The consumer owns its VM build, FIPS startup flags,
release configuration, and application-level runtime tests.

The SDK never silently falls back to a host OpenSSL installation or another
backend. These are engineering controls and recorded observations—not a
compliance conclusion. See [FIPS model](docs/fips-model.md).

## Hermeticity and portability

Sources, compilers, sysroots, build tools, and licenses are fetched by exact
URL and SHA-256. Build actions use declared inputs; the default BuildBuddy
execution image is digest-pinned and has action networking disabled.
The unavoidable upstream Configure/make boundary is delegated to
`rules_foreign_cc`; repository-owned staging and SDK assembly are Starlark or
compiled Go, with no repository shell scripts or source patches.

The checked-in BuildBuddy configuration supplies a digest-pinned Linux
execution image. `--config=local` disables remote services; local execution
requires the host facilities used by Bazel and `rules_foreign_cc`. SDK outputs
remain architecture-specific and require a compatible Linux kernel and CPU.

Read [Portability and hermeticity](docs/portability.md) before treating
“relocatable” as “runs everywhere.”

## Documentation

- [Documentation map](docs/README.md)
- [Architecture](docs/architecture.md)
- [FIPS model and safe language](docs/fips-model.md)
- [Portability and hermeticity](docs/portability.md)
- [Version and certificate maintenance](docs/maintenance.md)
- [Publishing and BCR preparation](docs/publishing.md)
- [Guide for AI coding agents](docs/agents/README.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

The rules are Apache-2.0. The SDK payload exposes the applicable upstream
license texts. Static linking and bundling do not remove a distributor's
license obligations. This repository's license inventory is engineering
documentation, not legal advice.
