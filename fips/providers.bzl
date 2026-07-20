"""Public providers exported by rules_fips."""

FipsCryptoInfo = provider(
    doc = "A built cryptographic module plus build and runtime evidence; not a compliance determination.",
    fields = {
        "backend": "Canonical backend name: openssl.",
        "certificate": "Referenced CMVP certificate identifier; this is not a validation claim for the output.",
        "include_dir": "Tree artifact containing consumer headers.",
        "manifest": "Machine-readable build and runtime evidence manifest.",
        "module_name": "Cryptographic module name documented by the certificate reference.",
        "module_version": "Reported module version or update-stream identity.",
        "runtime_files": "Runtime files required in addition to static archives.",
        "service_indicator": "How approved-service status is enforced or observed.",
        "static_libs": "Depset of static archives in deterministic link order.",
    },
)

FipsCryptoSdkInfo = provider(
    doc = "A normalized crypto SDK export for backend-neutral consumers such as rules_elixir_mix.",
    fields = {
        "activation_args": "Argument vector for the shell-free activation executable.",
        "activation_tool": "Target-configured activation executable.",
        "activation_tool_release_path": "SDK-relative deployment path of the activation executable.",
        "artifacts": "Named individual artifacts used to assemble deployment payloads.",
        "backend_metadata": "Opaque producer metadata; consumers must not branch on it.",
        "crypto": "Underlying FipsCryptoInfo provider.",
        "execution_wrapper": "Target-configured shell-free launcher for SDK-owned runtime loaders.",
        "execution_wrapper_environment": "Opaque environment templates required by execution_wrapper.",
        "execution_wrapper_release_path": "SDK-relative deployment path of execution_wrapper.",
        "fully_static": "Whether no runtime payload or activation is required.",
        "linkopts": "Additional backend-neutral system link options required by OTP.",
        "runtime_destinations": "SDK-relative destinations corresponding to runtime_files.",
        "runtime_environment": "Runtime environment templates rooted at {sysroot} or {activation_root}.",
        "runtime_files": "Ordered deployment payload files.",
        "sysroot": "Directory artifact containing the complete build SDK layout.",
    },
)

MuslSysrootInfo = provider(
    doc = "An integrity-pinned, static-capable musl libc sysroot.",
    fields = {
        "compiler_rt": "Compiler-rt builtins archive installed into the sysroot.",
        "compiler_rt_license": "LLVM compiler-rt license installed into the sysroot.",
        "files": "All files belonging to the immutable sysroot.",
        "license": "musl copyright and license file.",
        "libc": "musl shared libc used by portable OpenSSL-provider runtimes.",
        "loader": "Architecture-specific musl dynamic loader.",
        "revision": "Pinned upstream musl revision.",
        "resource_dir": "Clang resource directory containing target compiler-rt objects and headers.",
        "sysroot_path": "Execution-root-relative root containing headers, CRT objects, and static libraries.",
        "target_triplet": "musl target triplet represented by the sysroot.",
    },
)

HermeticMakeInfo = provider(
    doc = "A statically linked launcher for a pinned GNU make executable and musl runtime.",
    fields = {
        "binary": "Static launcher executable used for direct and recursive make invocations.",
        "files": "All files required by the launcher and pinned GNU make runtime.",
        "version": "Pinned GNU make version.",
    },
)

HermeticBashInfo = provider(
    doc = "A statically linked launcher for pinned GNU Bash and its musl runtime.",
    fields = {
        "binary": "Static launcher executable used at upstream Bash boundaries.",
        "files": "All files required by the launcher and pinned Bash runtime.",
        "version": "Pinned GNU Bash version.",
    },
)

ForeignToolboxInfo = provider(
    doc = "Pinned execution tools used only at unavoidable upstream Configure/make boundaries.",
    fields = {
        "applets": "BusyBox applet launcher files keyed by applet name.",
        "bin_dir": "Directory containing BusyBox applet symlinks.",
        "bash": "Pinned GNU Bash launcher.",
        "busybox": "Pinned static BusyBox executable.",
        "files": "All toolbox, GNU make, and Perl runtime inputs.",
        "make": "Static GNU make launcher.",
        "perl": "Relocatable Perl interpreter from the registered exec toolchain.",
        "sh": "Pinned BusyBox POSIX shell executable.",
    },
)

FipsPlatformInfo = provider(
    doc = "Architecture-specific values consumed by FIPS build actions.",
    fields = {
        "arch": "Canonical rules_fips architecture name.",
        "clang_files": "Files belonging to the pinned, architecture-specific Clang tool.",
        "clang_library_path": "Pinned native library search path required by LLVM executables.",
        "clang_resource_dir": "Clang resource directory used for native bootstrap compilation.",
        "clang_runtime_files": "Pinned native shared libraries required by LLVM executables.",
        "go_bin": "Pinned Go executable used to compile hermetic helper tools.",
        "go_files": "Files belonging to the pinned Go release.",
        "libc": "Target C library name.",
        "llvm_ar": "Pinned LLVM archiver.",
        "llvm_ld": "Pinned LLVM linker.",
        "llvm_nm": "Pinned LLVM symbol inspector.",
        "llvm_objcopy": "Pinned LLVM object copier.",
        "llvm_objdump": "Pinned LLVM object inspector.",
        "llvm_ranlib": "Pinned LLVM archive indexer.",
        "llvm_readelf": "Pinned LLVM ELF inspector.",
        "llvm_strip": "Pinned LLVM binary stripper.",
        "musl_revision": "Pinned musl upstream revision.",
        "musl_libc_file": "musl shared libc artifact for OpenSSL-provider bundles.",
        "musl_license_file": "musl license artifact for distribution notices.",
        "musl_loader_file": "musl loader artifact for OpenSSL-provider bundles.",
        "musl_loader_path": "Execution-root-relative musl loader path.",
        "musl_triplet": "Canonical musl target triplet.",
        "compiler_rt_path": "Compiler-rt builtins archive inside the musl sysroot.",
        "compiler_rt_license_path": "Compiler-rt license inside the musl sysroot.",
        "crt_dir": "Directory containing source-built musl CRT startup objects.",
        "crt_files": "Source-built musl CRT startup objects required by link actions.",
        "openssl_target": "OpenSSL Configure target.",
        "qemu_aarch64_file": "Pinned static qemu-aarch64 execution tool.",
        "qemu_aarch64_files": "Files belonging to the pinned qemu-aarch64 execution tool.",
        "resource_dir": "Clang resource directory supplied by the target sysroot.",
        "sysroot_files": "Source-built musl sysroot required by target build actions.",
        "sysroot_path": "Execution-root-relative path to the source-built musl sysroot.",
    },
)
