"""rules_foreign_cc-backed builds for validated cryptographic modules."""

load("@rules_foreign_cc//foreign_cc:defs.bzl", "cmake", "configure_make")
load("//fips:providers.bzl", "FipsCryptoInfo")

_TOOLCHAIN_TYPE = "//fips:toolchain_type"
_TARGET_AMD64 = "//fips/platforms:target_amd64"
_TARGET_ARM64 = "//fips/platforms:target_arm64"

def _file_named(files, basename):
    for file in files:
        if file.basename == basename:
            return file
    fail("rules_foreign_cc output did not contain %s" % basename)

def _directory_named(files, basename):
    for file in files:
        if file.is_directory and file.basename == basename:
            return file
    fail("rules_foreign_cc output did not contain directory %s" % basename)

def _sysroot(marker):
    return "$$(dirname $$(dirname $$(dirname $(execpath %s))))" % marker

def _boringssl_cache(marker, triplet, processor):
    clang_root = "$(execpath @fips_clang_amd64//sysroot:sysroot)"
    sysroot = _sysroot(marker)
    resource_dir = clang_root + "/lib/clang/22"
    compile_flags = " ".join([
        "--target=" + triplet,
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-O2",
        "-fPIC",
        "-Wno-unused-command-line-argument",
    ])
    link_flags = " ".join([
        "--target=" + triplet,
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "--rtlib=compiler-rt",
        "-fuse-ld=lld",
        "-static",
    ])
    return {
        "BUILD_SHARED_LIBS": "OFF",
        "CMAKE_AR": clang_root + "/bin/llvm-ar",
        "CMAKE_ASM_COMPILER": clang_root + "/bin/clang",
        "CMAKE_ASM_COMPILER_TARGET": triplet,
        "CMAKE_ASM_FLAGS": compile_flags,
        "CMAKE_C_COMPILER": clang_root + "/bin/clang",
        "CMAKE_C_COMPILER_TARGET": triplet,
        "CMAKE_CXX_COMPILER": clang_root + "/bin/clang++",
        "CMAKE_CXX_COMPILER_TARGET": triplet,
        "CMAKE_CXX_FLAGS": compile_flags + " -stdlib=libc++",
        "CMAKE_C_FLAGS": compile_flags,
        "CMAKE_EXE_LINKER_FLAGS": link_flags + " -stdlib=libc++",
        "CMAKE_POSITION_INDEPENDENT_CODE": "ON",
        "CMAKE_RANLIB": clang_root + "/bin/llvm-ranlib",
        "CMAKE_SHARED_LINKER_FLAGS": link_flags + " -stdlib=libc++",
        "CMAKE_SYSROOT": sysroot,
        "CMAKE_SYSTEM_NAME": "Linux",
        "CMAKE_SYSTEM_PROCESSOR": processor,
        "CMAKE_TRY_COMPILE_TARGET_TYPE": "STATIC_LIBRARY",
        "FIPS": "1",
        "GO_EXECUTABLE": "$(execpath @fips_go_amd64//sysroot:sysroot)/bin/go",
        "PERL_EXECUTABLE": "$(execpath //fips/toolchains:foreign_perl)",
    }

def _openssl_env(marker, triplet, loader):
    clang_root = "$(execpath @fips_clang_amd64//sysroot:sysroot)"
    sysroot = _sysroot(marker)
    resource_dir = sysroot + "/usr/lib/llvm22/lib/clang/22"
    compile_flags = " ".join([
        "--target=" + triplet,
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-B" + sysroot + "/usr/lib/",
        "-O2",
        "-fPIC",
    ])
    link_flags = " ".join([
        "--target=" + triplet,
        "--sysroot=" + sysroot,
        "-resource-dir=" + resource_dir,
        "-B" + sysroot + "/usr/lib/",
        "--rtlib=compiler-rt",
        "--unwindlib=libunwind",
        "-fuse-ld=lld",
        "-Wl,-S",
        "-Wl,-z,relro,-z,now",
        "-Wl,--dynamic-linker=/opt/fips-elixir/lib/" + loader,
        "-Wl,-rpath,/opt/fips-elixir/lib",
    ])
    return {
        "AR": clang_root + "/bin/llvm-ar",
        "CC": clang_root + "/bin/clang",
        "CFLAGS": compile_flags,
        "GOCACHE": "$$BUILD_TMPDIR/gocache",
        "HOME": "$$BUILD_TMPDIR",
        "LD": clang_root + "/bin/ld.lld",
        "LDFLAGS": link_flags,
        "LD_LIBRARY_PATH": "$(execpath //fips/toolchains:llvm_libxml2_amd64)/usr/lib/x86_64-linux-gnu:$(execpath //fips/toolchains:llvm_libicu_amd64)/usr/lib/x86_64-linux-gnu",
        "NM": clang_root + "/bin/llvm-nm",
        "OBJCOPY": clang_root + "/bin/llvm-objcopy",
        "OBJDUMP": clang_root + "/bin/llvm-objdump",
        "PERL": "$(execpath //fips/toolchains:foreign_perl)",
        "READELF": clang_root + "/bin/llvm-readelf",
        "SOURCE_DATE_EPOCH": "0",
        "STRIP": clang_root + "/bin/llvm-strip",
        "TMPDIR": "$$BUILD_TMPDIR",
    }

def _boringssl_finalize_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    foreign_files = ctx.attr.foreign[DefaultInfo].files.to_list()
    libcrypto = _file_named(foreign_files, "libcrypto.a")
    libssl = _file_named(foreign_files, "libssl.a")
    include_dir = _directory_named(foreign_files, "include")
    checker = ctx.actions.declare_file(ctx.label.name + "/bin/boring-fips-check")
    manifest = ctx.actions.declare_file(ctx.label.name + "/FIPS_BUILD.json")

    ctx.actions.run(
        arguments = [
            "boringssl",
            ctx.file.checker_source.path,
            libcrypto.path,
            libssl.path,
            include_dir.path,
            checker.path,
            manifest.path,
            platform.arch,
            platform.clang_cc,
            platform.llvm_readelf,
            platform.musl_triplet,
            platform.sysroot_path,
            platform.resource_dir,
            platform.musl_revision,
        ],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "LD_LIBRARY_PATH": platform.clang_library_path,
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.executable.validator,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [
                ctx.file.checker_source,
                ctx.file.license,
                libcrypto,
                libssl,
                include_dir,
            ],
            transitive = [
                platform.clang_files,
                platform.clang_runtime_files,
                platform.crt_files,
                platform.sysroot_files,
            ],
        ),
        mnemonic = "BoringSslFipsFinalize",
        outputs = [checker, manifest],
        progress_message = "Validating rules_foreign_cc BoringSSL FIPS outputs for %s" % platform.arch,
    )

    files = depset([
        libcrypto,
        libssl,
        include_dir,
        checker,
        ctx.file.license,
        manifest,
        platform.musl_license_file,
    ])
    return [
        DefaultInfo(files = files),
        FipsCryptoInfo(
            backend = "boringssl",
            certificate = "CMVP #5296",
            include_dir = include_dir,
            manifest = manifest,
            module_name = "BoringCrypto",
            module_version = "2023042800",
            runtime_files = depset([checker, ctx.file.license, platform.musl_license_file]),
            service_indicator = "per-service",
            static_libs = depset([libssl, libcrypto], order = "preorder"),
        ),
    ]

_boringssl_finalize = rule(
    implementation = _boringssl_finalize_impl,
    attrs = {
        "checker_source": attr.label(
            allow_single_file = [".c"],
            default = "//runtime:boring_fips_check.c",
        ),
        "foreign": attr.label(mandatory = True),
        "license": attr.label(
            allow_single_file = True,
            default = "@boringssl_src//:LICENSE",
        ),
        "validator": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = "//fips/private:fips_artifact_validator",
            executable = True,
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def boringssl_fips_static(name, visibility = None, tags = None):
    """Builds validated BoringSSL through rules_foreign_cc's CMake rule."""
    foreign_name = name + "_foreign"
    common = {}
    if tags != None:
        common["tags"] = tags

    cmake(
        name = foreign_name,
        build_data = [
            "@boringssl_src//:CMakeLists.txt",
            "@fips_clang_amd64//sysroot:sysroot",
            "@fips_go_amd64//sysroot:sysroot",
            "//fips/private:fips_artifact_validator",
            "//fips/toolchains:foreign_perl",
            "//fips/toolchains:llvm_libicu_amd64",
            "//fips/toolchains:llvm_libxml2_amd64",
        ] + select({
            _TARGET_AMD64: ["@musl_amd64_sysroot//:sysroot", "@musl_amd64_sysroot//:usr/include/stdio.h"],
            _TARGET_ARM64: ["@musl_arm64_sysroot//:sysroot", "@musl_arm64_sysroot//:usr/include/stdio.h"],
        }),
        cache_entries = select({
            _TARGET_AMD64: _boringssl_cache(
                "@musl_amd64_sysroot//:usr/include/stdio.h",
                "x86_64-linux-musl",
                "x86_64",
            ),
            _TARGET_ARM64: _boringssl_cache(
                "@musl_arm64_sysroot//:usr/include/stdio.h",
                "aarch64-linux-musl",
                "aarch64",
            ),
        }),
        configuration = "Release",
        env = {
            "GOCACHE": "$$BUILD_TMPDIR/gocache",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GONOSUMDB": "*",
            "GOPATH": "$$BUILD_TMPDIR/gopath",
            "GOPROXY": "off",
            "GOSUMDB": "off",
            "GOTOOLCHAIN": "local",
            "HOME": "$$BUILD_TMPDIR",
            "LD_LIBRARY_PATH": "$(execpath //fips/toolchains:llvm_libxml2_amd64)/usr/lib/x86_64-linux-gnu:$(execpath //fips/toolchains:llvm_libicu_amd64)/usr/lib/x86_64-linux-gnu",
            "PERL": "$(execpath //fips/toolchains:foreign_perl)",
            "SOURCE_DATE_EPOCH": "0",
            "TMPDIR": "$$BUILD_TMPDIR",
        },
        generate_crosstool_file = False,
        generate_args = ["-GNinja"],
        install = False,
        lib_source = "@boringssl_src//:srcs",
        out_static_libs = ["libcrypto.a", "libssl.a"],
        postfix_script = "$(execpath //fips/private:fips_artifact_validator) stage-boringssl $(execpath @boringssl_src//:CMakeLists.txt) $$BUILD_TMPDIR $$INSTALLDIR",
        targets = ["crypto", "ssl"],
        **common
    )

    final_args = dict(common)
    final_args["foreign"] = ":" + foreign_name
    if visibility != None:
        final_args["visibility"] = visibility
    _boringssl_finalize(
        name = name,
        **final_args
    )

def _openssl_finalize_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    core_files = ctx.attr.core[DefaultInfo].files.to_list()
    provider_files = ctx.attr.provider[DefaultInfo].files.to_list()
    libcrypto = _file_named(core_files, "libcrypto.a")
    libssl = _file_named(core_files, "libssl.a")
    include_dir = _directory_named(core_files, "include")
    openssl_bin = _file_named(core_files, "openssl")
    fips_module = _file_named(provider_files, "fips.so")
    manifest = ctx.actions.declare_file(ctx.label.name + "/FIPS_BUILD.json")
    core_license = ctx.actions.declare_file(ctx.label.name + "/licenses/openssl-core-LICENSE.txt")
    fips_license = ctx.actions.declare_file(ctx.label.name + "/licenses/openssl-fips-provider-LICENSE.txt")

    ctx.actions.symlink(output = core_license, target_file = ctx.file.core_license)
    ctx.actions.symlink(output = fips_license, target_file = ctx.file.fips_license)

    ctx.actions.run(
        arguments = [
            "openssl",
            openssl_bin.path,
            fips_module.path,
            ctx.file.openssl_config.path,
            libcrypto.path,
            libssl.path,
            manifest.path,
            platform.arch,
            platform.musl_loader_path,
            platform.sysroot_path,
            platform.llvm_readelf,
        ],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.executable.validator,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [
                ctx.file.core_license,
                ctx.file.fips_license,
                ctx.file.openssl_config,
                fips_module,
                include_dir,
                libcrypto,
                libssl,
                openssl_bin,
            ],
            transitive = [
                platform.clang_files,
                platform.sysroot_files,
            ],
        ),
        mnemonic = "OpenSslFipsFinalize",
        outputs = [manifest],
        progress_message = "Validating rules_foreign_cc OpenSSL FIPS outputs for %s" % platform.arch,
    )

    files = depset([
        libcrypto,
        libssl,
        include_dir,
        openssl_bin,
        fips_module,
        ctx.file.openssl_config,
        core_license,
        fips_license,
        manifest,
        platform.musl_libc_file,
        platform.musl_license_file,
        platform.musl_loader_file,
    ])
    return [
        DefaultInfo(files = files),
        FipsCryptoInfo(
            backend = "openssl",
            certificate = "CMVP #4985",
            include_dir = include_dir,
            manifest = manifest,
            module_name = "OpenSSL FIPS Provider",
            module_version = "3.1.2",
            runtime_files = depset([
                openssl_bin,
                fips_module,
                ctx.file.openssl_config,
                core_license,
                fips_license,
                platform.musl_libc_file,
                platform.musl_license_file,
                platform.musl_loader_file,
            ]),
            service_indicator = "provider-properties-fips=yes",
            static_libs = depset([libssl, libcrypto], order = "preorder"),
        ),
    ]

_openssl_finalize = rule(
    implementation = _openssl_finalize_impl,
    attrs = {
        "core": attr.label(mandatory = True),
        "core_license": attr.label(
            allow_single_file = True,
            default = "@openssl_core_src//:LICENSE.txt",
        ),
        "fips_license": attr.label(
            allow_single_file = True,
            default = "@openssl_fips_src//:LICENSE.txt",
        ),
        "openssl_config": attr.label(
            allow_single_file = [".cnf"],
            default = "//runtime:openssl-fips.cnf",
        ),
        "provider": attr.label(mandatory = True),
        "validator": attr.label(
            allow_single_file = True,
            cfg = "exec",
            default = "//fips/private:fips_artifact_validator",
            executable = True,
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def _openssl_foreign_build_data():
    return [
        "@fips_busybox_exec//:bin/busybox.static",
        "@fips_clang_amd64//sysroot:sysroot",
        "//fips/toolchains:foreign_perl",
        "//fips/toolchains:llvm_libicu_amd64",
        "//fips/toolchains:llvm_libxml2_amd64",
    ] + select({
        _TARGET_AMD64: ["@musl_amd64_sysroot//:sysroot", "@musl_amd64_sysroot//:usr/include/stdio.h"],
        _TARGET_ARM64: ["@musl_arm64_sysroot//:sysroot", "@musl_arm64_sysroot//:usr/include/stdio.h"],
    })

def _openssl_selected_env():
    return select({
        _TARGET_AMD64: _openssl_env(
            "@musl_amd64_sysroot//:usr/include/stdio.h",
            "x86_64-alpine-linux-musl",
            "ld-musl-x86_64.so.1",
        ),
        _TARGET_ARM64: _openssl_env(
            "@musl_arm64_sysroot//:usr/include/stdio.h",
            "aarch64-alpine-linux-musl",
            "ld-musl-aarch64.so.1",
        ),
    })

def _openssl_target():
    return select({
        _TARGET_AMD64: ["linux-x86_64"],
        _TARGET_ARM64: ["linux-aarch64"],
    })

def openssl_fips(name, visibility = None, tags = None):
    """Builds the OpenSSL core and validated provider with configure_make."""
    core_name = name + "_core_foreign"
    provider_name = name + "_provider_foreign"
    common = {}
    if tags != None:
        common["tags"] = tags

    configure_make(
        name = provider_name,
        args = [
            "-s",
            "-j8",
            "RANLIB=$$EXT_BUILD_ROOT$$/$(execpath @fips_clang_amd64//sysroot:sysroot)/bin/llvm-ranlib",
        ],
        build_data = _openssl_foreign_build_data(),
        configure_command = "Configure",
        configure_options = _openssl_target() + [
            "--libdir=lib",
            "enable-fips",
            "no-tests",
        ],
        configure_prefix = "$(execpath //fips/toolchains:foreign_perl)",
        env = _openssl_selected_env(),
        lib_source = "@openssl_fips_src//:srcs",
        out_include_dir = "",
        out_lib_dir = "lib/ossl-modules",
        out_shared_libs = ["fips.so"],
        targets = ["", "install_fips"],
        **common
    )

    configure_make(
        name = core_name,
        args = [
            "-s",
            "-j8",
            "RANLIB=$$EXT_BUILD_ROOT$$/$(execpath @fips_clang_amd64//sysroot:sysroot)/bin/llvm-ranlib",
        ],
        build_data = _openssl_foreign_build_data(),
        configure_command = "Configure",
        configure_options = _openssl_target() + [
            "--libdir=lib",
            "no-shared",
            "no-tests",
        ],
        configure_prefix = "$(execpath //fips/toolchains:foreign_perl)",
        env = _openssl_selected_env(),
        lib_source = "@openssl_core_src//:srcs",
        out_binaries = ["openssl"],
        out_static_libs = ["libcrypto.a", "libssl.a"],
        targets = ["build_sw", "install_sw"],
        **common
    )

    final_args = dict(common)
    final_args.update({
        "core": ":" + core_name,
        "provider": ":" + provider_name,
    })
    if visibility != None:
        final_args["visibility"] = visibility
    _openssl_finalize(
        name = name,
        **final_args
    )
