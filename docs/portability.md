# Portability and hermeticity

The output is a relocatable Linux crypto SDK, not a universal executable. The
build graph is integrity-pinned, but complete build-userspace isolation depends
on the selected Bazel execution platform.

## Deployment boundary

| Bazel config | Target SDK | Host packages required by the SDK runtime |
| --- | --- | --- |
| `linux_amd64` | Linux x86-64 + musl 1.2.5 | none |
| `linux_arm64` | Linux AArch64 + musl 1.2.5 | none |
| `linux_amd64_glibc` | Linux x86-64 + glibc 2.35 ABI | none |
| `linux_arm64_glibc` | Linux AArch64 + glibc 2.35 ABI | none |

The deployment payload carries its OpenSSL FIPS provider plus the selected
loader and runtime libraries. Native tools invoke OpenSSL and declared consumer
programs through that loader using SDK-relative paths. Nothing silently searches
for a host OpenSSL installation, provider configuration, loader, or libc.
Loader and runtime-library runfiles are content-copied into action-owned Bazel
outputs before launch; external-repository symlinks are never used as the
execution contract.

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
- pure-Starlark repository rules reject dangling or escaping archive symlinks
  before any extracted tree becomes an action input;
- custom source URLs also require SHA-256;
- Clang/LLD 22.1.8, Go 1.26.5, GNU make, Perl, CMake 4.4.0,
  Ninja 1.13.2, pkgconf 3.0.4, BusyBox 1.37.0-r31, QEMU 11.0.2-r1,
  sysroots, and licenses are pinned;
- AMD64 and Arm64 C/C++ toolchains use explicit musl or glibc sysroots;
- network access is blocked for build, validation, and packaging actions;
- manifests expose resolved source identity rather than a floating label.

Bootlin archives and Alpine packages are immutable input formats, not host
distribution requirements. They are extracted into declared Bazel inputs and
validated as complete execution or target closures. The selected libc ABI,
not the distribution that published an archive, defines output compatibility.
Bootlin archives are reduced deterministically to their target sysroot; pseudo-
device links, resolver configuration, and unrelated cross-tool binaries never
enter the action graph.

This is why a custom URL without a digest is not accepted: it would make two
nominally identical builds free to consume different bytes.

## Execution-platform hermeticity

Starlark supplies exact argument vectors to a static driver. The driver invokes
declared Perl and Make directly; upstream Make recipes use declared Bash and
BusyBox. The action environment contains only declared tool paths. No generated
shell command, host compiler, host loader, or host library lookup is used.

The maintainer BuildBuddy configuration supplies a Linux execution image
pinned by digest and disables action networking. Bazel and its JVM run in that
outer worker image; build-language interpreters, compilers, Bash, Make, Perl,
loaders, and libraries remain declared action inputs. The build-tool boundary
validates each ELF dependency against those inputs before downstream actions
can use it, so a missing library cannot fall through to the worker image.

`--config=local` intentionally disables remote execution and cache services.
The actions retain their declared userspace; Bazel, its JVM, the Linux kernel,
and CPU remain outside the action-input graph. A digest-pinned remote image
also fixes the Bazel worker userspace around those actions.

Downstream repositories do not inherit a dependency's `.bazelrc`. To reproduce
the maintainer boundary, they must select an equivalent digest-pinned execution
platform or import the documented BuildBuddy settings into their root
configuration.

## C/C++ and Cargo execution contract

The registered C/C++ toolchains keep the build-host ABI separate from the
application ABI. The GNU Linux execution platforms select a declared glibc
2.35 compiler, linker, headers, loader, and runtime closure for tools built in
the execution configuration. They never fall through to Bazel's local
auto-configuration or `/usr/bin/gcc`. Application targets independently select
the AMD64 or Arm64 musl/glibc toolchain.

Application executables are statically linked by default. Shared-library
actions—including Rust proc macros—never receive `-static`; their declared
compiler runtime is linked without relying on a host `libgcc_s`, and their ELF
metadata rejects default host-library directories. A consumer may
explicitly enable `rules_fips_dynamic_executable` only when another rule owns a
complete static launcher plus loader/library runfiles. Such an ELF contains a
deliberately nonexistent interpreter marker and cannot accidentally start from
the worker's execroot layout. The static launcher invokes its declared loader
with an explicit library search path, validates the complete `DT_NEEDED`
closure before execution, and makes glibc ignore its host cache. Dynamic
executables carry `DF_1_NODEFLIB`, so an incomplete glibc closure fails instead
of searching default directories.

Link-driver runtime-selection flags are limited to link actions, and Clang's
specific unused-command-line-argument diagnostic is disabled there. Strict
Rust consumers can therefore use `-Dwarnings` without toolchain-authored linker
messages weakening source diagnostics.

Cross links pass the checksum-pinned compiler-rt builtins archive for the
target CPU as a declared link input after Bazel's object files. Clang may use
only the target sysroot's declared GCC runtime for remaining symbols. It never
derives Arm64 builtins from the AMD64 execution package or searches a worker
runtime directory.

Current `rules_rust` Cargo build-script actions resolve the target C/C++
toolchain separately from the GNU execution Rust toolchain. The selected
target compiler tree and sysroot are declared inputs to the build-script action,
while the build script and proc macro remain GNU-executable. The repository's
consumer matrix inspects that action closure and runs a build script that calls
both the C compiler and CMake for AMD64 and Arm64 after changing into its output
directory. The adapter passes native compiler tools as declared inputs and uses
`rules_rust`'s action-root expansion to resolve their absolute execroot paths once
before process startup, and the declared static launcher anchors toolchain-owned sysroot, include,
resource, library, and linker arguments to that same execroot. Native tools and
their sysroot therefore remain reachable after a build system changes its
working directory.

CMake and Ninja are checksum-pinned declared tools. A `cargo_build_script`
that invokes them lists their public targets in `tools` and passes them through
`$(execpath ...)`; `rules_rust` converts those values to stable absolute paths.
The ruleset intentionally does not publish cwd-relative `CMAKE` or `NINJA`
template variables. A source-built zlib 1.3.2 supplies the only non-libc shared
library required by the Rust/LLVM execution tools. No host compiler, host
`libz.so`, or action-time download completes that path. The native C compiler
needs no per-crate annotation; rules that invoke additional native tools use
the normal declared-tool attributes of their build-rule API.

Target pkg-config SDKs follow the same separation. `target_pkg_config_sdk`
binds one execution-configured pkg-config executable to the target `.pc`
metadata, headers, libraries, and support files. The Rust adapter carries that
provider's complete depset into the Cargo build-script action and publishes
only absolute paths resolved through `rules_rust`'s action-root expansion.
Host `PATH`, `PKG_CONFIG_PATH`, and pkgconf's built-in system include/library
paths are empty. Cross compilation is explicit, and an incomplete target SDK
fails closed. The regression matrix builds unmodified
`yeslogic-fontconfig-sys` 6.0.1 for AMD64 and Arm64 musl from an AMD64 GNU
execution platform.

The normalized SDK's activation and runtime-launcher execution tools are a
separate contract again: they compile from the pinned, static Go toolchain for
the real GNU execution CPU and do not request `//fips:toolchain_type`. This
prevents a language adapter from forcing the musl/FIPS application ABI onto a
GNU worker. Their Go cache and module state are declared outputs; the
executor-provided temporary directory is write-only compiler scratch and is
never searched for inputs, loaders, libraries, or SDK content.

## Libc profiles

musl minimizes the deployment closure. The glibc profile uses a 2.35 ABI
baseline so outputs run on Ubuntu 22.04 and newer compatible systems without
being built against a distribution image. Both profiles package their loader
and runtime libraries. OpenSSL 3 still loads the FIPS provider as a module, so
the portable unit is the declared SDK payload rather than one static binary.
Neither libc choice changes the compliance boundary.
