# Changelog

All notable user-facing changes are recorded here. Signed Git tags and GitHub
releases identify the exact source; this project is not yet published to the
Bazel Central Registry.

## 0.3.2 - 2026-07-21

### Fixed

- `fips_rust_toolchain` binds its default runtime, launcher, and toolchain-type
  labels to `rules_fips`, so external repositories no longer resolve those
  defaults in the caller's workspace.
- Cargo build scripts receive the resolved target C/C++ compiler and archiver
  as declared execroot-relative tools. `rules_rust` makes those paths absolute
  before execution, and the static tool launcher normalizes declared
  execroot-rooted compiler arguments, so direct native builds and CMake remain
  hermetic after changing directories.

## 0.3.1 - 2026-07-21

### Fixed

- Dynamic runtime launchers preserve the public executable identity when they
  dispatch to a declared sibling `.real-*` program. OTP frontends such as
  `escript` therefore retain their dispatch semantics without exposing the
  hidden runtime filename as `argv[0]`.

## 0.3.0 - 2026-07-21

### Added

- Declared glibc 2.35 execution C/C++ toolchains for AMD64 and Arm64, separate
  from musl and glibc application targets.
- Hermetic CMake and Ninja tools for Cargo native build scripts.
- A public `fips_rust_toolchain` adapter with a source-built, checksum-pinned
  zlib execution dependency.
- Strict C, C++, Rust, proc-macro, and Cargo build-script consumer coverage.
- Static runtime launchers that carry target loaders and libraries through
  declared runfiles for both native and cross-architecture execution.

### Changed

- Application executables are statically linked by default; shared-library
  actions never inherit `-static` and reject default host-library directories.
- Link-only runtime flags are warning-free under Rust `-Dwarnings` consumers.
- Dynamic executable launch now validates the complete declared ELF dependency
  closure, rejects host-absolute dependencies, disables the glibc cache/default
  search path, and strips ambient `LD_*` state.
- Pinned Bash, Make, BusyBox, and LLVM execution tools now carry a prerequisite
  closure stamp that rejects missing, ambiguous, or host-provided ELF inputs.
- Every extracted source, compiler, SDK, and runtime archive rejects dangling
  or escaping symlinks. Bootlin inputs retain only the declared target sysroot,
  excluding pseudo-device and host-configuration trees.
- Native build actions use libc's built-in `C` locale and never consult worker
  locale databases.
- Static Go helper compilation keeps cache and module state in declared action
  outputs. Go compiler scratch uses the executor's action-private temporary
  directory only; it is never an input or persistent state authority.
- SDK execution helpers bind their source and tool labels in the
  `rules_fips` module, so an external consumer can compile them on a GNU
  execution platform without resolving a FIPS target toolchain there.
- Compiler, libc, CMake, Ninja, Go, Rust, QEMU, and Bazel pins were refreshed to
  the versions documented in `docs/versions.md`.
- The source-built zlib input has two official, byte-identical HTTPS locations
  guarded by the same SHA-256, avoiding a single upstream availability point.
- Rust execution tools, proc macros, and Cargo build scripts now remain on an
  ABI-neutral GNU execution toolchain while selecting musl/glibc application
  C/C++ inputs independently.
- Cross links select the checksum-pinned target-architecture compiler-rt
  archive explicitly after object inputs, with only the declared target GCC
  runtime available as fallback. The execution-architecture Clang resource
  tree can no longer select the wrong builtins archive.
- The normalized crypto SDK contract now carries a fail-closed build-time ELF
  interpreter marker and action-owned runtime copies.

### Removed

- Execroot-relative ELF interpreters and runtime search paths.
- Unused legacy compiler-runtime fields from the public platform provider.

## 0.2.1 - 2026-06-26

- Published the signed source release preceding the strict-consumer and
  execution-runtime work above.
