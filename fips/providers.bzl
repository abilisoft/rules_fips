"""Public providers exported by rules_fips."""

FipsCryptoInfo = provider(
    doc = "A built cryptographic module and the evidence required to consume it.",
    fields = {
        "backend": "Canonical backend name: boringcrypto or openssl.",
        "certificate": "CMVP certificate identifier.",
        "include_dir": "Tree artifact containing consumer headers.",
        "manifest": "Machine-readable build and validation manifest.",
        "module_name": "Validated cryptographic module name.",
        "module_version": "Validated module version.",
        "runtime_files": "Runtime files required in addition to static archives.",
        "service_indicator": "How approved-service status is enforced or observed.",
        "static_libs": "Depset of static archives in deterministic link order.",
    },
)

FipsRuntimeInfo = provider(
    doc = "A staged OTP/Elixir runtime backed by a FIPS cryptographic module.",
    fields = {
        "backend": "Canonical cryptographic backend name.",
        "distribution": "Relocatable distribution tarball rooted at /opt/fips-elixir.",
        "manifest": "Runtime build and validation manifest.",
        "otp_version": "OTP source version.",
        "elixir_version": "Elixir source version.",
    },
)

FipsBootstrapPlatformInfo = provider(
    doc = "Pinned native tools used to construct the target musl sysroot and policy tools.",
    fields = {
        "arch": "Canonical rules_fips architecture name.",
        "clang_cc": "Pinned native Clang C compiler.",
        "clang_cxx": "Pinned native Clang C++ compiler.",
        "clang_files": "Files belonging to the pinned Clang release.",
        "cmake_bin": "Pinned CMake executable required by the BoringCrypto security policy.",
        "cmake_files": "Files belonging to the pinned CMake release.",
        "glibc_sysroot_files": "Pinned bootstrap glibc sysroot files.",
        "glibc_sysroot_path": "Execution-root-relative bootstrap glibc sysroot.",
        "gnu_triplet": "GNU architecture triplet used for bootstrap builds.",
        "llvm_ar": "Pinned LLVM archiver.",
        "llvm_ranlib": "Pinned LLVM archive indexer.",
        "llvm_readelf": "Pinned LLVM ELF inspector.",
        "musl_triplet": "Canonical musl target triplet.",
    },
)

MuslSysrootInfo = provider(
    doc = "A source-built, static-only musl libc sysroot.",
    fields = {
        "compiler_rt": "Compiler-rt builtins archive installed into the sysroot.",
        "compiler_rt_license": "LLVM compiler-rt license installed into the sysroot.",
        "license": "musl copyright and license file.",
        "revision": "Pinned upstream musl revision.",
        "sysroot": "Tree artifact containing headers, CRT objects, and static libraries.",
        "target_triplet": "musl target triplet represented by the sysroot.",
    },
)

PolicyNinjaInfo = provider(
    doc = "The exact statically linked Ninja executable named by the BoringCrypto security policy.",
    fields = {
        "binary": "Pinned Ninja executable.",
        "files": "All runtime files needed by the executable.",
        "version": "Pinned Ninja version.",
    },
)

FipsPlatformInfo = provider(
    doc = "Architecture-specific values consumed by FIPS build actions.",
    fields = {
        "arch": "Canonical rules_fips architecture name.",
        "boringssl_processor": "CMake processor used by BoringSSL.",
        "build_compiler_rt_files": "Pinned compiler-rt files for the native OTP cross-build bootstrap.",
        "build_compiler_rt_path": "Native compiler-rt builtins archive.",
        "build_sysroot_files": "Pinned glibc sysroot files for a native OTP cross-build bootstrap.",
        "build_sysroot_path": "Execution-root-relative native bootstrap sysroot.",
        "build_triplet": "Canonical triplet of the Bazel execution host.",
        "clang_cc": "Pinned Clang C compiler used for validated BoringCrypto assembly.",
        "clang_cxx": "Pinned Clang C++ compiler used for validated BoringCrypto assembly.",
        "clang_files": "Files belonging to the pinned, architecture-specific Clang tool.",
        "cmake_bin": "Pinned CMake executable required by the BoringCrypto security policy.",
        "cmake_files": "Files belonging to the pinned CMake release.",
        "go_bin": "Pinned Go executable required by the BoringCrypto security policy.",
        "go_files": "Files belonging to the pinned Go release.",
        "gnu_triplet": "GNU target triplet.",
        "libc": "Target C library name.",
        "llvm_ar": "Pinned LLVM archiver.",
        "llvm_ranlib": "Pinned LLVM archive indexer.",
        "llvm_readelf": "Pinned LLVM ELF inspector.",
        "musl_revision": "Pinned musl upstream revision.",
        "musl_triplet": "Canonical musl target triplet.",
        "compiler_rt_path": "Compiler-rt builtins archive inside the musl sysroot.",
        "compiler_rt_license_path": "Compiler-rt license inside the musl sysroot.",
        "openssl_target": "OpenSSL Configure target.",
        "sysroot_files": "Source-built musl sysroot required by target build actions.",
        "sysroot_path": "Execution-root-relative path to the source-built musl sysroot.",
    },
)
