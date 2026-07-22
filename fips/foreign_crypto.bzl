"""Hermetic OpenSSL FIPS source builds and normalized runtime evidence."""

load(
    "@rules_cc//cc:action_names.bzl",
    "CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME",
    "CPP_LINK_EXECUTABLE_ACTION_NAME",
    "CPP_LINK_STATIC_LIBRARY_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//fips:providers.bzl", "FipsCryptoInfo", "ForeignToolboxInfo")
load("//fips:source_versions.bzl", "OPENSSL_CORE_SOURCE", "OPENSSL_FIPS_CERTIFICATE_REFERENCE", "OPENSSL_FIPS_SOURCE")

_TOOLCHAIN_TYPE = Label("//fips:toolchain_type")

_EXECUTION_ROOT_PREFIX = "__RULES_FIPS_EXEC_ROOT__/"

def _execution_path(path):
    return path if path.startswith("/") else _EXECUTION_ROOT_PREFIX + path

def _file_named(files, basename):
    for file in files:
        if file.basename == basename:
            return file
    fail("OpenSSL source output did not contain %s" % basename)

def _directory_named(files, basename):
    for file in files:
        if file.is_directory and file.basename == basename:
            return file
    fail("OpenSSL source output did not contain directory %s" % basename)

def _runtime_library_path(platform):
    directories = []
    for file in platform.libc_runtime_files.to_list():
        if file.dirname not in directories:
            directories.append(file.dirname)
    return ":".join(directories)

def _cc_command_lines(ctx, cc_toolchain, requested_features):
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = requested_features,
        unsupported_features = ctx.disabled_features,
    )
    compile_variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        user_compile_flags = ["-fPIC"],
    )
    dynamic_link_variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_linking_dynamic_library = True,
    )
    executable_link_variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
    )
    return struct(
        archiver = cc_common.get_tool_for_action(
            action_name = CPP_LINK_STATIC_LIBRARY_ACTION_NAME,
            feature_configuration = feature_configuration,
        ),
        compile = cc_common.get_memory_inefficient_command_line(
            action_name = C_COMPILE_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = compile_variables,
        ),
        dynamic_link = cc_common.get_memory_inefficient_command_line(
            action_name = CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = dynamic_link_variables,
        ),
        executable_link = cc_common.get_memory_inefficient_command_line(
            action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = executable_link_variables,
        ),
        compiler = cc_common.get_tool_for_action(
            action_name = C_COMPILE_ACTION_NAME,
            feature_configuration = feature_configuration,
        ),
    )

def _source_root(configure):
    if configure.basename != "Configure":
        fail("OpenSSL source marker must be named Configure")
    return configure.dirname

def _source_outputs(ctx):
    if ctx.attr.mode == "core":
        return struct(
            artifacts = [
                ctx.actions.declare_file(ctx.label.name + "/bin/openssl"),
                ctx.actions.declare_directory(ctx.label.name + "/include"),
                ctx.actions.declare_file(ctx.label.name + "/lib/libcrypto.a"),
                ctx.actions.declare_file(ctx.label.name + "/lib/libssl.a"),
                ctx.actions.declare_directory(ctx.label.name + "/lib/pkgconfig"),
            ],
            configure_options = ["no-shared", "no-tests"],
            make_targets = ["build_sw", "install_sw"],
            staged = [
                struct(destination_index = 0, directory = False, source = "bin/openssl"),
                struct(destination_index = 1, directory = True, source = "include"),
                struct(destination_index = 2, directory = False, source = "lib/libcrypto.a"),
                struct(destination_index = 3, directory = False, source = "lib/libssl.a"),
                struct(destination_index = 4, directory = True, source = "lib/pkgconfig"),
            ],
        )
    return struct(
        artifacts = [ctx.actions.declare_file(ctx.label.name + "/lib/ossl-modules/fips.so")],
        configure_options = ["enable-fips", "no-tests"],
        make_targets = ["build_sw", "install_fips"],
        staged = [struct(destination_index = 0, directory = False, source = "lib/ossl-modules/fips.so")],
    )

def _openssl_source_build_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    cc_toolchain = find_cc_toolchain(ctx)
    toolbox = ctx.attr.toolbox[ForeignToolboxInfo]
    source = _source_outputs(ctx)
    command_lines = _cc_command_lines(
        ctx,
        cc_toolchain,
        ctx.features + (["rules_fips_dynamic_executable"] if ctx.attr.mode == "core" else []),
    )
    work_dir = ctx.actions.declare_directory(ctx.label.name + "/work")
    config = ctx.actions.declare_file(ctx.label.name + "/build.json")
    outputs = [
        {
            "destination": source.artifacts[item.destination_index].path,
            "directory": item.directory,
            "source": item.source,
        }
        for item in source.staged
    ]
    link_flags = command_lines.executable_link if ctx.attr.mode == "core" else command_lines.dynamic_link
    environment = {
        "AR": _execution_path(command_lines.archiver),
        "CC": _execution_path(command_lines.compiler),
        "CFLAGS": " ".join(command_lines.compile),
        "CONFIG_SHELL": _execution_path(toolbox.sh.path),
        "CPPFLAGS": "",
        "CXX": _execution_path(command_lines.compiler),
        "LDFLAGS": " ".join(link_flags),
        "LD": _execution_path(command_lines.compiler),
        "LANG": "C",
        "LC_ALL": "C",
        "NM": _execution_path(platform.llvm_nm),
        "PATH": _execution_path(toolbox.bin_dir),
        "RANLIB": _execution_path(platform.llvm_ranlib),
        "SOURCE_DATE_EPOCH": "0",
        "ZERO_AR_DATE": "1",
    }
    ctx.actions.write(
        output = config,
        content = json.encode({
            "configure": ctx.file.configure.path,
            "configure_args": [
                platform.openssl_target,
                "--prefix=/",
                "--openssldir=/ssl",
                "--libdir=lib",
            ] + source.configure_options,
            "environment": environment,
            "make": toolbox.make.path,
            "make_args": ["-s", "-j%d" % ctx.attr.jobs],
            "make_targets": source.make_targets,
            "outputs": outputs,
            "perl": toolbox.perl.path,
            "shell": toolbox.sh.path,
            "source_dir": _source_root(ctx.file.configure),
            "work_dir": work_dir.path,
        }),
    )
    ctx.actions.run(
        arguments = [config.path],
        env = {
            "LANG": "C",
            "LC_ALL": "C",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = ctx.executable.driver,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [config, ctx.file.configure],
            transitive = [
                cc_toolchain.all_files,
                ctx.attr.driver[DefaultInfo].files,
                ctx.attr.driver[DefaultInfo].default_runfiles.files,
                ctx.attr.source[DefaultInfo].files,
                toolbox.files,
            ],
        ),
        mnemonic = "OpenSslFipsSourceBuild",
        outputs = source.artifacts + [work_dir],
        progress_message = "Building OpenSSL %s for %s/%s" % (ctx.attr.mode, platform.libc, platform.arch),
    )
    return [DefaultInfo(files = depset(source.artifacts))]

_openssl_source_build = rule(
    implementation = _openssl_source_build_impl,
    attrs = {
        "configure": attr.label(allow_single_file = True, mandatory = True),
        "driver": attr.label(
            cfg = "exec",
            default = Label("//fips/private:foreign_build_driver"),
            executable = True,
        ),
        "jobs": attr.int(default = 8),
        "mode": attr.string(mandatory = True, values = ["core", "provider"]),
        "source": attr.label(mandatory = True),
        "toolbox": attr.label(
            cfg = "exec",
            default = Label("//fips/toolchains:foreign_toolbox"),
            providers = [ForeignToolboxInfo],
        ),
    },
    fragments = ["cpp"],
    toolchains = [_TOOLCHAIN_TYPE] + use_cc_toolchain(),
)

def _openssl_finalize_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    core_files = ctx.attr.core[DefaultInfo].files.to_list()
    provider_files = ctx.attr.provider[DefaultInfo].files.to_list()
    libcrypto = _file_named(core_files, "libcrypto.a")
    libssl = _file_named(core_files, "libssl.a")
    include_dir = _directory_named(core_files, "include")
    pkg_config_dir = _directory_named(core_files, "pkgconfig")
    openssl_bin = _file_named(core_files, "openssl")
    fips_module = _file_named(provider_files, "fips.so")
    manifest = ctx.actions.declare_file(ctx.label.name + "/FIPS_BUILD.json")
    core_license = ctx.actions.declare_file(ctx.label.name + "/licenses/openssl-core-LICENSE.txt")
    fips_license = ctx.actions.declare_file(ctx.label.name + "/licenses/openssl-fips-provider-LICENSE.txt")
    runtime_entries = [
        struct(destination = "bin/openssl", file = openssl_bin),
        struct(destination = "lib/ossl-modules/fips.so", file = fips_module),
        struct(destination = "ssl/openssl.cnf", file = ctx.file.openssl_config),
        struct(destination = "licenses/openssl-core-LICENSE.txt", file = core_license),
        struct(destination = "licenses/openssl-fips-provider-LICENSE.txt", file = fips_license),
        struct(destination = "licenses/libc-LICENSE.txt", file = platform.libc_license_file),
    ] + [
        struct(destination = "lib/" + entry.destination, file = entry.file)
        for entry in platform.libc_runtime_entries
    ]

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
            platform.libc_runtime_entries[0].file.path,
            _runtime_library_path(platform),
            platform.llvm_readelf,
            platform.qemu_aarch64_file.path if platform.qemu_aarch64_file else "-",
            OPENSSL_FIPS_CERTIFICATE_REFERENCE,
            OPENSSL_FIPS_SOURCE.version,
            OPENSSL_FIPS_SOURCE.sha256,
            OPENSSL_CORE_SOURCE.version,
            OPENSSL_CORE_SOURCE.sha256,
        ],
        env = {
            "LANG": "C",
            "LC_ALL": "C",
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
                platform.libc_runtime_files,
                platform.qemu_aarch64_files,
                platform.sysroot_files,
            ],
        ),
        mnemonic = "OpenSslFipsFinalize",
        outputs = [manifest],
        progress_message = "Checking OpenSSL FIPS outputs for %s/%s" % (platform.libc, platform.arch),
    )

    files = depset(direct = [
        libcrypto,
        libssl,
        include_dir,
        pkg_config_dir,
        openssl_bin,
        fips_module,
        ctx.file.openssl_config,
        core_license,
        fips_license,
        manifest,
        platform.libc_license_file,
    ], transitive = [platform.libc_runtime_files])
    return [
        DefaultInfo(files = files),
        FipsCryptoInfo(
            backend = "openssl",
            certificate = OPENSSL_FIPS_CERTIFICATE_REFERENCE,
            include_dir = include_dir,
            manifest = manifest,
            module_name = "OpenSSL FIPS Provider",
            module_version = OPENSSL_FIPS_SOURCE.version,
            pkg_config_dir = pkg_config_dir,
            runtime_entries = runtime_entries,
            runtime_files = depset(direct = [
                openssl_bin,
                fips_module,
                ctx.file.openssl_config,
                core_license,
                fips_license,
                platform.libc_license_file,
            ], transitive = [platform.libc_runtime_files]),
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
            default = Label("@openssl_core_src//:LICENSE.txt"),
        ),
        "fips_license": attr.label(
            allow_single_file = True,
            default = Label("@openssl_fips_src//:LICENSE.txt"),
        ),
        "openssl_config": attr.label(
            allow_single_file = [".cnf"],
            default = Label("//runtime:openssl-fips.cnf"),
        ),
        "provider": attr.label(mandatory = True),
        "validator": attr.label(
            cfg = "exec",
            default = Label("//fips/private:fips_artifact_validator"),
            executable = True,
        ),
    },
    toolchains = [_TOOLCHAIN_TYPE],
)

def openssl_fips(name, visibility = None, tags = None):
    """Builds the OpenSSL core and certificate-referenced provider.

    Args:
      name: Crypto target name.
      visibility: Optional target visibility.
      tags: Optional tags applied to generated targets.
    """
    core_name = name + "_core_source"
    provider_name = name + "_provider_source"
    common = {}
    if tags != None:
        common["tags"] = tags

    _openssl_source_build(
        name = provider_name,
        configure = Label("@openssl_fips_src//:Configure"),
        mode = "provider",
        source = Label("@openssl_fips_src//:srcs"),
        **common
    )
    _openssl_source_build(
        name = core_name,
        configure = Label("@openssl_core_src//:Configure"),
        mode = "core",
        source = Label("@openssl_core_src//:srcs"),
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
