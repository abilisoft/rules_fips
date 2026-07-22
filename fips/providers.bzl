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
        "pkg_config_dir": "Tree artifact containing producer-installed pkg-config metadata.",
        "runtime_files": "Runtime files required in addition to static archives.",
        "runtime_entries": "Runtime files paired with normalized SDK-relative destinations.",
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

TargetPkgConfigSdkInfo = provider(
    doc = "A declared target SDK and pkg-config executable for Cargo build-script actions.",
    fields = {
        "files": "Complete executable and target SDK input closure.",
        "libdirs": "Execroot-relative directories containing the declared .pc files.",
        "pkg_config": "Declared execution-configured pkg-config executable.",
        "sysroot": "Execroot-relative target SDK root.",
    },
)

MuslSysrootInfo = provider(
    doc = "The integrity-pinned musl runtime used by declared execution-tool launchers.",
    fields = {
        "files": "All files belonging to the immutable runtime.",
        "license": "musl copyright and license file.",
        "libc": "musl shared libc used by declared execution tools.",
        "loader": "Architecture-specific musl dynamic loader.",
        "revision": "Pinned upstream musl revision.",
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

HermeticRuntimeEnvironmentInfo = provider(
    doc = "Additional declared environment required by a hermetic runtime tool.",
    fields = {
        "path_lists": "Environment variables mapped to ordered lists of declared execution paths.",
        "reentry_variables": "Environment variables whose value is the hermetic launcher path.",
        "variables": "Literal environment variables required by the runtime tool.",
    },
)

HermeticRuntimeInfo = provider(
    doc = "A normalized target loader and exact shared-library closure with no compiler dependency.",
    fields = {
        "libc_runtime_entries": "Runtime files paired with normalized destinations.",
        "libc_runtime_files": "Declared target loader and shared-library closure.",
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
        "go_bin": "Pinned Go executable used to compile hermetic helper tools.",
        "go_files": "Files belonging to the pinned Go release.",
        "libc": "Target C library name.",
        "libc_license_file": "License file distributed with the target C runtime.",
        "libc_runtime_entries": "Runtime files paired with normalized lib/ destinations.",
        "libc_runtime_files": "Declared target C runtime loader and shared-library closure.",
        "libc_version": "Target C runtime ABI version.",
        "llvm_nm": "Pinned LLVM symbol inspector.",
        "llvm_ranlib": "Pinned LLVM archive indexer.",
        "llvm_readelf": "Pinned LLVM ELF inspector.",
        "openssl_target": "OpenSSL Configure target.",
        "qemu_aarch64_file": "Optional pinned static qemu-aarch64 tool for x86-to-ARM cross execution.",
        "qemu_aarch64_files": "Files belonging to the optional declared qemu-aarch64 execution tool.",
        "sysroot_files": "Declared target sysroot required by build and validation actions.",
    },
)
