# rules_fips

`rules_fips` builds relocatable, musl-based Erlang/OTP 29.0.3 and Elixir
1.20.2 distributions with FIPS mode enforced at startup. OpenSSL is the
default backend; a fully static BoringSSL/BoringCrypto backend is optional.

The supported target matrix is Linux `amd64` and Linux `arm64`:

| Backend | Crypto linkage | Validated module |
| --- | --- | --- |
| OpenSSL, default | static `libcrypto`/`libssl`; dynamic `fips.so` provider | OpenSSL FIPS Provider 3.1.2, CMVP #4985 |
| BoringSSL, optional | fully static BoringCrypto | BoringCrypto 2023042800, CMVP #5296 |

OpenSSL's provider remains a shared object intentionally. The validated
OpenSSL module boundary is the provider, so replacing it with a static object
would no longer be the module described by certificate #4985. OTP's crypto
NIF and the OpenSSL 3.5.7 core are still statically linked.

## Build

The module API defaults to OpenSSL:

```starlark
load("@rules_fips//fips:defs.bzl", "fips_elixir_distribution")

fips_elixir_distribution(
    name = "elixir_fips",
)
```

Use `backend = "boringssl_fips_static"` to select BoringSSL. The repository
contains complete examples:

```sh
bazel --config=linux_amd64 build //examples:elixir_openssl_fips
bazel --config=linux_amd64 build //examples:elixir_boringssl_fips_static

bazel --config=linux_arm64 build //examples:elixir_openssl_fips
bazel --config=linux_arm64 build //examples:elixir_boringssl_fips_static
```

Each target produces a deterministic archive and JSON provenance manifest:

```text
bazel-bin/examples/elixir_openssl_fips.tar.gz
bazel-bin/examples/elixir_openssl_fips.json
```

Extract the archive anywhere and keep `opt/fips-elixir` together. The static
launcher resolves that directory at runtime; it does not require `/bin/sh` or
a fixed installation prefix:

```sh
tar -xzf bazel-bin/examples/elixir_openssl_fips.tar.gz
./opt/fips-elixir/bin/elixir -e \
  'IO.inspect({System.version(), :crypto.info_fips(), :crypto.info()[:link_type]})'
```

## FIPS enforcement

The build uses OTP's upstream configuration controls, including
`--enable-fips`, `--enable-static-nifs=yes`, `--enable-static-drivers=yes`,
`--disable-dynamic-ssl-lib`, and release optimization. It does not enable a
debug runtime.

The shell-free launcher always starts BEAM with `-crypto fips_mode true` and
runs an Erlang boot guard before user code. Build-time validators also execute
the target runtime and require:

- `crypto:info_fips()` to return `enabled`;
- OTP to report `link_type := static`;
- the selected validated module and version to be active;
- OpenSSL provider installation and every provider KAT to pass; or
- BoringCrypto's FIPS mode to be active and attempts to disable it to fail.

Packaging audits every ELF file. BoringSSL output may not contain an ELF
interpreter or `DT_NEEDED` dependency. The OpenSSL output may depend only on
the packaged musl loader/libc and its packaged FIPS provider.

Neither OTP nor BoringSSL is patched. OTP expects OpenSSL's broader API, so the
BoringSSL variant supplies consumer-side compatibility declarations under
`compat/boringssl`. Missing algorithms remain unavailable; the overlay does
not modify BoringCrypto or implement cryptography.

## Bazel and hermeticity

The foreign projects are driven by `rules_foreign_cc` 0.15.1:

- BoringSSL uses its upstream CMake build;
- OpenSSL, OTP, and Elixir use upstream Configure/Make entry points;
- repository rules and build definitions are Starlark;
- repository-owned staging, validation, packaging, and launchers are static Go
  tools; and
- the repository contains no shell scripts and no `ctx.actions.run_shell`.

`rules_foreign_cc` exposes `postfix_script` as a string API. Three one-line
hooks invoke the declared static staging tool for outputs that the upstream
install layouts do not expose directly. They contain no shell file operations
or build logic. BoringSSL's native install target cannot be used selectively:
it also installs and therefore forces a link of the unused `bssl` C++ CLI.

All source archives and tools have SHA-256 integrity pins. Build actions use
declared Clang, musl sysroots, CMake, Ninja, Go, GNU Make, Perl, BusyBox, and
runtime-library inputs; downloads during actions are disabled and actions
request network blocking.

`rules_foreign_cc` itself executes generated scripts with `/bin/bash`. The
default remote build closes that outer userspace boundary by pinning a
BuildBuddy execution image by digest in `.bazelrc`. The Ubuntu-derived
execution image and the pinned Ubuntu packages needed by the official LLVM
binary are build tools only. They are not present in, or required by, the
musl deployment archive.

A local build with remote execution disabled still depends on the local
kernel and `/bin/bash`, so it is useful for verification but is not claimed to
have the same byte-hermetic execution boundary as the default pinned remote
build. A separate output remains necessary per CPU architecture.

## Default pins

| Component | Version or identity |
| --- | --- |
| Bazel | 9.2.0 |
| Erlang/OTP | 29.0.3 |
| Elixir | 1.20.2 |
| OpenSSL core | 3.5.7 LTS |
| OpenSSL FIPS provider | 3.1.2, CMVP #4985 |
| BoringSSL/BoringCrypto | commit `a430310d6563c0734ddafca7731570dfb683dc19`, module 2023042800, CMVP #5296 |
| musl target sysroot | 1.2.6-r2 |
| LLVM/Clang | 22.1.6 compiler; 22.1.3 target runtime packages |
| CMake | 3.27.4 |
| Ninja | 1.11.1 |
| Go | 1.21.1 |
| GNU Make | 4.4.1 |
| rules_foreign_cc | 0.15.1 |
| rules_perl | 1.1.2 |

Ordinary release upgrades are pin and checksum changes followed by the full
two-architecture matrix. A validated module upgrade is different: it requires
reviewing the new CMVP certificate, security policy, module identity, and
listed operational environments rather than merely selecting the newest
library tag.

## Compliance boundary

This repository proves the selected validated module identity, target
linkage, startup mode, KAT result, and tested service behavior. It does not
make an Elixir application or an unlisted deployment environment
FIPS-certified. The produced musl environments are not listed operational
environments on certificates #4985 or #5296. A regulated deployment must
follow the applicable security policy and determine whether vendor
affirmation or a separate CMVP path is required.

## Licensing

The package carries upstream license and notice files. The principal terms
are Apache-2.0 for OTP, Elixir, OpenSSL, and `rules_foreign_cc`; MIT for musl;
Apache-2.0 WITH LLVM-exception for LLVM; and BoringSSL's bundled
ISC/OpenSSL/SSLeay notices. Linux UAPI header sources retain their upstream
terms. Static linking does not itself violate those licenses, but a
distributor remains responsible for notices and any source or attribution
obligations. This is an engineering inventory, not legal advice.

- [OpenSSL FIPS certificate #4985](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4985)
- [BoringCrypto certificate #5296](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/5296)
- [BuildBuddy RBE execution properties](https://www.buildbuddy.io/docs/rbe-platforms/)
