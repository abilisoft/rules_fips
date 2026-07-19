"""Shell-free runtime auditing and deterministic distribution packaging."""

load(
    "//fips:providers.bzl",
    "FipsCryptoInfo",
    "FipsElixirRuntimeInfo",
    "FipsLauncherInfo",
    "FipsOtpRuntimeInfo",
    "FipsRuntimeInfo",
)

_TOOLCHAIN_TYPE = "//fips:toolchain_type"

def _file_named(files, basename, required = True):
    for file in files:
        if file.basename == basename:
            return file
    if required:
        fail("required FIPS input %s was not provided" % basename)
    return None

def _is_license(file):
    name = file.basename
    return (
        name.endswith(".txt") or
        name.startswith("COPYING") or
        name == "COPYRIGHT" or
        name == "LICENSE"
    )

def _runtime_package_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    crypto = ctx.attr.crypto[FipsCryptoInfo]
    otp = ctx.attr.otp[FipsOtpRuntimeInfo]
    elixir = ctx.attr.elixir[FipsElixirRuntimeInfo]
    launcher = ctx.attr.launcher[FipsLauncherInfo]
    if launcher.backend != crypto.backend or otp.backend != crypto.backend:
        fail("OTP, launcher, and crypto backends must match")

    runtime_files = crypto.runtime_files.to_list()
    checker = _file_named(runtime_files, "boring-fips-check", required = False)
    openssl_bin = _file_named(runtime_files, "openssl", required = False)
    fips_module = _file_named(runtime_files, "fips.so", required = False)
    openssl_config = _file_named(runtime_files, "openssl-fips.cnf", required = False)
    operational = {}
    overlays = []
    if crypto.backend == "openssl":
        if not openssl_bin or not fips_module or not openssl_config:
            fail("OpenSSL runtime requires openssl, fips.so, and openssl-fips.cnf")
        overlays.extend([
            ("opt/fips-elixir/bin/openssl", openssl_bin),
            ("opt/fips-elixir/lib/ossl-modules/fips.so", fips_module),
            ("opt/fips-elixir/ssl/openssl-fips.cnf", openssl_config),
            ("opt/fips-elixir/lib/" + platform.musl_loader_file.basename, platform.musl_loader_file),
            ("opt/fips-elixir/lib/" + platform.musl_libc_file.basename, platform.musl_libc_file),
        ])
        for file in [
            openssl_bin,
            fips_module,
            openssl_config,
            platform.musl_loader_file,
            platform.musl_libc_file,
        ]:
            operational[file.path] = True
    else:
        if not checker:
            fail("BoringSSL FIPS runtime requires boring-fips-check")
        overlays.append(("opt/fips-elixir/bin/boring-fips-check", checker))
        operational[checker.path] = True

    license_names = {}
    for file in runtime_files:
        if file.path in operational or not _is_license(file):
            continue
        destination = "opt/fips-elixir/licenses/" + file.basename
        if destination in license_names and license_names[destination] != file.path:
            fail("duplicate runtime license basename: %s" % file.basename)
        license_names[destination] = file.path
        overlays.append((destination, file))
    overlays.extend([
        ("opt/fips-elixir/licenses/erlang-otp.txt", ctx.file.otp_license),
        ("opt/fips-elixir/licenses/elixir.txt", ctx.file.elixir_license),
        ("opt/fips-elixir/licenses/compiler-rt.txt", ctx.file.compiler_rt_license),
    ])

    packager = ctx.actions.declare_file(ctx.label.name + "_tools/runtime_packager")
    packager_go_state = ctx.actions.declare_directory(ctx.label.name + "_tools/go_state")
    ctx.actions.run(
        arguments = [
            "build",
            "-trimpath",
            "-o",
            packager.path,
            ctx.file.packager_source.path,
        ],
        env = {
            "CGO_ENABLED": "0",
            "GOCACHE": "/proc/self/cwd/" + packager_go_state.path + "/cache",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": "amd64",
            "GOPATH": "/proc/self/cwd/" + packager_go_state.path + "/path",
            "GOTOOLCHAIN": "local",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = platform.go_bin,
        execution_requirements = {"block-network": "1"},
        inputs = depset(direct = [ctx.file.packager_source], transitive = [platform.go_files]),
        mnemonic = "RuntimePackagerCompile",
        outputs = [packager, packager_go_state],
        progress_message = "Compiling hermetic runtime packager",
    )

    distribution = ctx.actions.declare_file(ctx.label.name + ".tar.gz")
    manifest = ctx.actions.declare_file(ctx.label.name + ".json")
    arguments = ctx.actions.args()
    arguments.add_all([
        distribution.path,
        manifest.path,
        crypto.backend,
        platform.arch,
        otp.version,
        elixir.version,
        platform.musl_revision,
        platform.musl_loader_file.basename,
        platform.musl_libc_file.basename,
        otp.root.path,
        elixir.root.path,
        ctx.file.boot_beam.path,
        launcher.binary.path,
        crypto.manifest.path,
    ])
    for destination, source in overlays:
        arguments.add(destination)
        arguments.add(source.path)
    ctx.actions.run(
        arguments = [arguments],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = packager,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [
                packager,
                otp.root,
                elixir.root,
                ctx.file.boot_beam,
                launcher.binary,
                crypto.manifest,
                ctx.file.otp_license,
                ctx.file.elixir_license,
                ctx.file.compiler_rt_license,
            ] + runtime_files + [source for _, source in overlays],
        ),
        mnemonic = "FipsRuntimePackage",
        outputs = [distribution, manifest],
        progress_message = "Auditing and packaging %s FIPS runtime for %s" % (
            crypto.backend,
            platform.arch,
        ),
    )
    return [
        DefaultInfo(files = depset([distribution, manifest])),
        FipsRuntimeInfo(
            backend = crypto.backend,
            distribution = distribution,
            elixir_version = elixir.version,
            manifest = manifest,
            otp_version = otp.version,
        ),
    ]

fips_runtime_package = rule(
    implementation = _runtime_package_impl,
    attrs = {
        "boot_beam": attr.label(allow_single_file = [".beam"], mandatory = True),
        "compiler_rt_license": attr.label(
            allow_single_file = True,
            default = "@compiler_rt_22_1_3_license//file",
        ),
        "crypto": attr.label(mandatory = True, providers = [FipsCryptoInfo]),
        "elixir": attr.label(mandatory = True, providers = [FipsElixirRuntimeInfo]),
        "elixir_license": attr.label(
            allow_single_file = True,
            default = "@elixir_src//:LICENSE",
        ),
        "launcher": attr.label(mandatory = True, providers = [FipsLauncherInfo]),
        "otp": attr.label(mandatory = True, providers = [FipsOtpRuntimeInfo]),
        "otp_license": attr.label(
            allow_single_file = True,
            default = "@otp_src//:LICENSE.txt",
        ),
        "packager_source": attr.label(
            allow_single_file = [".go"],
            default = "//tools/runtime_packager:main.go",
        ),
    },
    doc = "Audits ELF linkage and creates a deterministic runtime archive without shell tools.",
    toolchains = [_TOOLCHAIN_TYPE],
)
