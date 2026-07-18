# `rules_fips`: static Elixir/OTP with BoringCrypto

This experiment is building a relocatable Elixir 1.20.2 and Erlang/OTP 29.0.3
distribution whose native ELF files are fully static musl executables. OTP's
`crypto` NIF is built into BEAM and linked to the exact BoringCrypto module
identified by FIPS 140-3 certificate [#5296][cmvp-5296]:

```text
Elixir -> OTP crypto (static NIF) -> BoringCrypto 2023042800 (static) -> musl
```

The target is intended to support Linux `amd64` and `arm64`. It contains no shared
objects, ELF interpreter, `DT_NEEDED` entry, glibc dependency, Ubuntu runtime,
or separately loaded crypto provider.

## Status

This is a private experimental snapshot, not a released `rules_fips` API.
The complete `amd64` distribution and the standalone `arm64` BoringCrypto
layer have been built and verified. The complete `arm64` OTP/Elixir
distribution is still in progress.

The current custom rules use `ctx.actions.run_shell` to orchestrate upstream
foreign builds. They therefore do not yet meet the project's intended
pure-Starlark/idiomatic-Bazel design standard. Upstream OTP, Elixir, musl, and
LLVM still use their own shell/configure/make build systems; the next rules
iteration must expose those tools and build stages honestly rather than hide
the orchestration in monolithic embedded shell actions.

The root Dockerfiles
and `scripts/container-*` files are retained only as earlier comparison
prototypes; they are not inputs to `rules_fips` and do not define its runtime
environment.

## Build

Use Bazelisk or Bazel 9.2.0; `.bazelversion` pins the version:

```sh
bazel --output_user_root="$PWD/.local/bazel-output" \
  build --repo_contents_cache= --config=linux_amd64 \
  //examples:elixir_boringcrypto_fips

bazel --output_user_root="$PWD/.local/bazel-output" \
  build --repo_contents_cache= --config=linux_arm64 \
  //examples:elixir_boringcrypto_fips
```

To pin the execution userspace as well, use the wrapper. It selects the
matching architecture from the host, runs in the immutable multi-platform
`python:3.14.5-trixie@sha256:11591407222400cafc1b2bd03fe09a90988f091fc9ddff4a901f80ceb02b78b3`
image, and downloads the matching official Bazel binary only after checking
its architecture-specific SHA-256:

```sh
./scripts/hermetic-bazel.sh

./scripts/hermetic-bazel.sh \
  build --repo_contents_cache= --config=linux_arm64 \
  //examples:elixir_boringcrypto_fips
```

The outputs are:

```text
bazel-bin/examples/elixir_boringcrypto_fips.tar.gz
bazel-bin/examples/elixir_boringcrypto_fips.json
```

The second command cross-builds on `amd64` and selects a native toolchain on
an `arm64` execution host. On `amd64`, the rule follows OTP's documented
cross-build procedure: it first builds a same-release native bootstrap Erlang,
uses that to compile target-independent OTP and Elixir bytecode, and uses
Clang's `aarch64-linux-musl` target for native code. The final target-runtime
check needs AArch64 binfmt/QEMU on an `amd64` builder. That emulator is a
build-time verification requirement only; it is not packaged or required on
an ARM deployment host.

Extract the tarball at `/`, or relocate `opt/fips-elixir` as a unit. The
launcher resolves its installation root and verifies FIPS before starting user
code:

```sh
/opt/fips-elixir/bin/boring-fips-check
/opt/fips-elixir/bin/elixir --version
/opt/fips-elixir/bin/elixir -e \
  'IO.inspect({:crypto.info_fips(), :crypto.info()})'
```

## What “enforced” means

The build uses OTP's upstream `--enable-fips`, `--enable-static-nifs`,
`--enable-static-drivers`, and `--disable-dynamic-ssl-lib` controls. The
launcher always passes `-crypto fips_mode true` and runs a boot guard before
user code. The build and boot checks require all of the following:

- `crypto:info_fips()` is `enabled`;
- OTP reports `link_type := static` and a linked BoringSSL version;
- `crypto:enable_fips_mode(false)` returns `false` and mode remains enabled;
- an unapproved MD5 request is rejected while SHA-256 succeeds;
- BoringCrypto's service indicator reports approved status for SHA-256 and
  non-approved status for MD5;
- every packaged ELF has no interpreter and no dynamic dependencies.

Neither the OTP nor BoringSSL source tree is patched. OTP does not officially
target BoringSSL's deliberately smaller OpenSSL-compatible API, so the build
does use consumer-side compatibility headers under `compat/boringssl`. They
mark unsupported algorithms unavailable and adapt omitted metadata/lifecycle
APIs; they do not modify BoringCrypto or add cryptographic implementations.

## Pins, hermeticity, and upgrades

All fetched sources and tools use HTTPS plus exact SHA-256 values. Build
actions receive declared toolchain/source inputs, clear the default shell
environment, disable Go module/toolchain downloads, and request network
blocking. Archives are created with stable ordering, timestamps, and numeric
ownership. The important default identities are:

| Component | Pin |
| --- | --- |
| Erlang/OTP | 29.0.3 |
| Elixir | 1.20.2 |
| BoringCrypto | 2023042800, commit `a430310d6563c0734ddafca7731570dfb683dc19` |
| BoringCrypto policy archive | SHA-256 `2d5339b756dbf1ceb4fdc4b1c8f19e32ded055292dc57827a6592f15ca9d359f` |
| musl | commit `b306b16af15c89a04d8e0c55cac2dadbeb39c083` |
| LLVM/Clang runtimes | 16.0.0 |
| Bazel | 9.2.0 |

For byte-reproducible execution, `scripts/hermetic-bazel.sh` pins the build
image rather than relying on whatever shell/core utilities a workstation
happens to have. Docker and the host Linux kernel remain the outer execution
boundary. A native builder of each CPU architecture removes QEMU/binfmt from
the trusted build environment; cross-verifying ARM adds that emulator to the
boundary.

Version upgrades are source-pin changes, not source patches. OTP, Elixir,
musl, and build-tool releases can be updated independently after both platform
builds pass. Changing the BoringCrypto commit/module is different: it changes
the validated module identity and requires a new certificate/security-policy
review.

The original Google Cloud Storage policy-archive URL currently returns 403
because anonymous callers lack `storage.objects.get`. The first source URL is
a timestamped Wayback copy of that exact object; Bazel accepts it only when its
bytes match the policy archive SHA-256 above. The inaccessible original URL is
retained as a secondary provenance URL.

## Portability and compliance boundary

Static musl removes deployment dependencies on a distribution's glibc,
`libcrypto.so`, `libssl.so`, C++ runtime, and crypto-provider search paths. A
separate artifact is still required per CPU, and Linux kernel/syscall behavior
is still part of the operating environment. The Elixir command is also a
script, so the deployment environment needs `/bin/sh`; this is a relocatable
Linux distribution, not one universal executable for every OS and CPU.

The repository proves that the validated module is built at its required
identity, statically linked, enters FIPS mode, and rejects tested unapproved
services. It does **not** make the whole Elixir application FIPS-certified.
The musl/static environments produced here are not listed operational
environments on certificate #5296. A regulated deployment must follow the
[BoringCrypto security policy][policy-5296] and determine whether its exact
operational environment needs vendor affirmation or a CMVP validation path.

## Licensing

The output includes the corresponding upstream notice files for
BoringSSL/BoringCrypto, Erlang/OTP, Elixir, musl, LLVM
compiler-rt/libc++/libc++abi/libunwind, and Linux UAPI headers. The principal terms are
Apache-2.0 for OTP and Elixir, MIT for musl, Apache-2.0 WITH LLVM-exception for
LLVM runtimes, and BoringSSL's bundled ISC/OpenSSL/SSLeay notices. Linux
header sources retain their upstream terms. Static linking does not by itself
prohibit distribution, but compliance with notices and source/code-offer
obligations must be reviewed for the way the artifact is shipped. This is an
engineering inventory, not legal advice.

[cmvp-5296]: https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/5296
[policy-5296]: https://csrc.nist.gov/CSRC/media/projects/cryptographic-module-validation-program/documents/security-policies/140sp5296.pdf
