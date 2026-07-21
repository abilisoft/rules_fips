# rules_fips

[![CI](https://github.com/abilisoft/rules_fips/actions/workflows/ci.yml/badge.svg)](https://github.com/abilisoft/rules_fips/actions/workflows/ci.yml)
[![CodeQL](https://github.com/abilisoft/rules_fips/actions/workflows/codeql.yml/badge.svg)](https://github.com/abilisoft/rules_fips/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/abilisoft/rules_fips/badge)](https://securityscorecards.dev/viewer/?uri=github.com/abilisoft/rules_fips)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Hermetic Bazel rules for building a normalized OpenSSL FIPS crypto SDK. The SDK
contains static archives and headers for consumers, plus the provider, config,
selected libc runtime, and shell-free activation/launch tools needed at
deployment.

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
- `fips.so`, `openssl.cnf`, OpenSSL, the selected loader/libc, and license/evidence
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
| Target C libraries | musl 1.2.5 and glibc 2.35 ABI baseline |
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

Select `linux_amd64_glibc` or `linux_arm64_glibc` for the glibc 2.35 ABI
baseline. That baseline is compatible with Ubuntu 22.04 and newer without
making Ubuntu—or any distribution—part of the target contract.

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

The exported C/C++ contract also supplies the declared GNU execution toolchain
needed by transitive build tools, independently of musl/glibc application
targets. Executables are static by default; shared-library links never inherit
`-static`. An explicitly dynamic executable is fail-closed unless its owning
rule carries the SDK's static launcher, loader, and runtime-library runfiles.
This is the contract consumed by `rules_elixir_mix` when it normalizes every
native executable in a source-built OTP tree.

Rust consumers that compile native code in Cargo build scripts can use
`fips_rust_toolchain` to wrap a normal `rules_rust` toolchain. The adapter keeps
build scripts and proc macros on the declared GNU execution ABI, makes the
target C/C++ toolchain tree visible to Cargo's action, and applies Rust's static
CRT only to executable crates. Its execution closure includes a source-built,
checksum-pinned zlib; it never searches the worker for `libz.so`, a compiler,
or a target sysroot. Compiler, archiver, and sysroot paths remain valid when a
native build changes into a Cargo or CMake output directory. See
[Portability](docs/portability.md) for the tested AMD64/Arm64 and musl/glibc
matrix.

## Hermeticity and portability

Sources, compilers, sysroots, build tools, and licenses are fetched by exact
URL and SHA-256. Build actions use declared inputs; the default BuildBuddy
execution image is digest-pinned and has action networking disabled.
Starlark invokes a small statically compiled driver for the filesystem/process
operations Bazel cannot express. The driver starts upstream OpenSSL Configure,
declared Perl, declared Make, and the declared shell directly; it never emits
or evaluates repository-authored shell. There are no source patches.

The checked-in BuildBuddy configuration supplies a digest-pinned Linux
execution image. `--config=local` disables remote services. Build actions still
use the same declared compilers, sysroots, interpreters, utilities, and runtime
libraries; the remaining host boundary is Bazel itself plus the Linux kernel
and CPU. SDK outputs remain architecture-specific.

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
