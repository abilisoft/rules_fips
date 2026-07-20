# rules_fips

[![CI](https://github.com/abilisoft/rules_fips/actions/workflows/ci.yml/badge.svg)](https://github.com/abilisoft/rules_fips/actions/workflows/ci.yml)
[![CodeQL](https://github.com/abilisoft/rules_fips/actions/workflows/codeql.yml/badge.svg)](https://github.com/abilisoft/rules_fips/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/abilisoft/rules_fips/badge)](https://securityscorecards.dev/viewer/?uri=github.com/abilisoft/rules_fips)
[![License](https://img.shields.io/github/license/abilisoft/rules_fips)](LICENSE)

Hermetic Bazel rules for building a relocatable Erlang/OTP and Elixir runtime
that starts with OpenSSL FIPS mode enforced.

> [!IMPORTANT]
> The project records build and runtime evidence. It does not certify,
> validate, approve, or guarantee the FIPS compliance of an application or
> deployment.

> [!NOTE]
> [`v0.1.0`](https://github.com/abilisoft/rules_fips/tree/v0.1.0) is a verified
> signed GitHub tag but is intentionally not published to BCR yet. Pin its
> verified commit directly as shown in
> [Publishing](docs/publishing.md#consume-before-bcr). A signed tag
> identifies source; it does not change the FIPS claim boundary above.

## The useful part

One macro produces two target-specific files:

```text
elixir_fips.tar.gz   relocatable runtime tree
elixir_fips.json     build, linkage, source, and runtime-check evidence
```

The current tested catalog selects:

| Component | Selection |
| --- | --- |
| Erlang/OTP | 29.0.3 |
| Elixir | 1.20.2 |
| OpenSSL core | 3.5.7 LTS |
| OpenSSL FIPS provider | 3.1.2, referencing CMVP certificate #4985 |
| Targets | Linux AMD64 and Linux Arm64 |
| C library | musl |
| Build compiler | Clang/LLD 22.1.8 |
| Arm64 validation | static QEMU 11.0.2, build-time only |

The OpenSSL core build produces static `libcrypto.a` and `libssl.a` archives.
OTP's crypto integration embeds `libcrypto.a`, and OTP's supported
static-NIF/static-driver options are enabled. Directly executed OTP helper
programs are static musl executables. The BEAM executable and OpenSSL command
use the bundled musl loader and libc; the launcher invokes them through paths
resolved inside the extracted tree. The runtime archive also carries OpenSSL
3's required `fips.so` provider. It does not use the deployment machine's
OpenSSL or libc packages.

## Build it

A local AMD64 build:

```console
bazel build --config=local --config=linux_amd64 \
  //examples:elixir_openssl_fips
```

Cross-compile the Arm64 archive from the supported Linux AMD64 execution
platform. Build-time provider and BEAM checks run through pinned static QEMU;
this is emulated validation, not native Arm64 hardware testing:

```console
bazel build --config=local --config=linux_arm64 \
  //examples:elixir_openssl_fips
```

Keep the extracted tree together and use its launcher:

```console
tar -xzf bazel-bin/examples/elixir_openssl_fips.tar.gz
./opt/fips-elixir/bin/elixir -e \
  'IO.inspect({System.version(), :crypto.info_fips()})'
```

The launcher resolves the runtime relative to itself. The
`opt/fips-elixir` directory is an archive layout, not a required host install
location.

### Why this is not one fully static executable

Neither Elixir bytecode nor the BEAM VM alone imposes this boundary: OTP
supports static NIFs. OpenSSL 3's ordinary FIPS path is a dynamically loaded
provider, however, and a completely static musl process cannot provide that
module-loading model. This build therefore keeps BEAM musl-dynamic while
embedding the OpenSSL core and bundles `fips.so`, the musl loader, and libc.
The portable unit is the resulting archive, not one ELF executable. It is
self-contained with respect to deployment userspace, but it still needs a
compatible Linux kernel and target CPU.

## Use the rules

```starlark
load("@rules_fips//fips:defs.bzl", "fips_elixir_distribution")

fips_elixir_distribution(
    name = "elixir_fips",
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
the runtime:

```console
bazel build --config=local //fips:source_pins
```

## What “enforced” means here

The build uses OTP's upstream `--enable-fips` and static-NIF switches. It does
not patch OTP, Elixir, or OpenSSL source.

Before packaging, declared tools verify architecture and linkage, run
`openssl fipsinstall`, load the provider, and start OTP with FIPS mode enabled.
The packaged launcher repeats the startup requirement and an Erlang boot guard
fails before user code if the invariant is missing.

Those are engineering controls and recorded observations—not a compliance
conclusion. See [FIPS model](docs/fips-model.md) for the exact claim boundary.

## Hermeticity and portability

Sources, compilers, sysroots, build tools, and licenses are fetched by exact
URL and SHA-256. Build actions use declared inputs; the default BuildBuddy
execution image is digest-pinned and has action networking disabled.
The unavoidable upstream Configure/make boundary is delegated to
`rules_foreign_cc`; repository-owned staging and packaging are Starlark or
compiled Go, with no repository shell scripts or source patches.

The checked-in BuildBuddy configuration supplies a digest-pinned Linux
execution image. `--config=local` disables remote services; local execution
requires the host facilities used by Bazel and `rules_foreign_cc`. Deployment
archives are distribution-independent within their documented Linux kernel
and CPU boundary, not universal binaries.

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

The rules are Apache-2.0. Produced archives carry the applicable upstream
license texts. Static linking and bundling do not remove a distributor's
license obligations. This repository's license inventory is engineering
documentation, not legal advice.
