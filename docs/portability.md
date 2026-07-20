# Portability and hermeticity

The output is a relocatable Linux crypto SDK, not a universal executable. The
build graph is integrity-pinned, but complete build-userspace isolation depends
on the selected Bazel execution platform.

## Deployment boundary

| Bazel config | Target SDK | Host packages required by the SDK runtime |
| --- | --- | --- |
| `linux_amd64` | Linux x86-64 + musl | none from the host OpenSSL/glibc stack |
| `linux_arm64` | Linux AArch64 + musl | none from the host OpenSSL/glibc stack |

The deployment payload carries its OpenSSL FIPS provider, musl loader, and musl
libc. Native tools invoke OpenSSL and declared consumer programs through that
loader using SDK-relative paths. Nothing silently searches for a host OpenSSL
installation or provider configuration.

Relocation works only while the SDK runtime layout remains intact. A consumer
may re-root the files, but it must preserve the normalized destinations and
render the declared `{sysroot}` and `{activation_root}` templates.

Portability still has hard edges:

- AMD64 and Arm64 are separate outputs.
- The host must provide a compatible Linux kernel and CPU instruction set.
- A container shares the host kernel and does not change CPU architecture.
- Arm64 build-time runtime checks execute under pinned QEMU user-mode
  emulation; they are not a native-hardware result.
- Files from different SDK builds must not be mixed.
- Technical portability does not establish a certificate-covered operational
  environment.

## Build-input hermeticity

Repository and build actions use declared, immutable inputs:

- source and binary archives use exact HTTPS URLs and SHA-256;
- custom source URLs also require SHA-256;
- Clang/LLD 22.1.8, Go 1.26.5, GNU make, Perl,
  BusyBox 1.37.0-r31, QEMU 11.0.2-r1, sysroots, and licenses are pinned;
- AMD64 and Arm64 C/C++ toolchains use explicit musl sysroots;
- network access is blocked for build, validation, and packaging actions;
- manifests expose resolved source identity rather than a floating label.

This is why a custom URL without a digest is not accepted: it would make two
nominally identical builds free to consume different bytes.

## Execution-platform hermeticity

`rules_foreign_cc` necessarily executes the upstream Configure/make command
language through Bash. The repository does not hide that boundary or replace
it with embedded shell scripts.

Pinned BusyBox utilities and pinned Perl are placed before the execution
platform in each foreign-build `PATH`. The outer Bash interpreter remains an
execution-platform input because `rules_foreign_cc` generates Bash actions;
the default remote configuration supplies it from the digest-pinned image.

The maintainer BuildBuddy configuration supplies a Linux execution image
pinned by digest and disables action networking. In that mode, Bash and the
remaining execution userspace come from the selected image rather than an
unversioned worker.

`--config=local` intentionally disables remote execution and cache services.
A local build still uses the host kernel and the host Bash selected by Bazel's
shell action mechanism. All fetched project/tool inputs remain pinned, but the
local execution userspace is not byte-for-byte the pinned remote image. Do not
claim otherwise.

Downstream repositories do not inherit a dependency's `.bazelrc`. To reproduce
the maintainer boundary, they must select an equivalent digest-pinned execution
platform or import the documented BuildBuddy settings into their root
configuration.

## Why musl

musl removes the ordinary deployment dependency on a distribution-specific
glibc version and makes the remaining dependency set small enough to expose
and audit. A consumer can statically link the OpenSSL core, but OpenSSL 3 still
loads the FIPS provider as a module. The portable unit is consequently the
declared SDK runtime payload, not one static executable. musl does not make one
SDK work on every kernel or confer FIPS status.
