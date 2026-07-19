"""Cacheable Elixir bytecode and FIPS boot-module stages."""

load("@rules_foreign_cc//foreign_cc:defs.bzl", "configure_make")
load(
    "//fips:providers.bzl",
    "FipsElixirRuntimeInfo",
    "FipsOtpBootstrapInfo",
    "FipsOtpRuntimeInfo",
)
load("//fips:source_versions.bzl", "ELIXIR_SOURCE")

def _toolbox_shell():
    return "$(execpath //fips/toolchains:foreign_toolbox_shell)"

def _foreign_path(prefix):
    return ":".join([
        prefix,
        "$$(dirname %s)" % _toolbox_shell(),
        "$$(dirname $(execpath //fips/toolchains:foreign_perl))",
        "/bin",
    ])

def _directory_named(files, basename):
    for file in files:
        if file.is_directory and file.basename == basename:
            return file
    fail("rules_foreign_cc output did not contain directory %s" % basename)

def _bootstrap_artifact_impl(ctx):
    bootstrap = ctx.attr.bootstrap[FipsOtpBootstrapInfo]
    artifacts = {
        "erl": bootstrap.erl,
        "erlc": bootstrap.erlc,
        "escript": bootstrap.escript,
        "root": bootstrap.root,
    }
    return [DefaultInfo(files = depset([artifacts[ctx.attr.kind]]))]

_bootstrap_artifact = rule(
    implementation = _bootstrap_artifact_impl,
    attrs = {
        "bootstrap": attr.label(mandatory = True, providers = [FipsOtpBootstrapInfo]),
        "kind": attr.string(mandatory = True, values = ["erl", "erlc", "escript", "root"]),
    },
)

def _otp_tools_artifact_impl(ctx):
    return [DefaultInfo(files = depset([ctx.attr.otp[FipsOtpRuntimeInfo].tools_ebin]))]

_otp_tools_artifact = rule(
    implementation = _otp_tools_artifact_impl,
    attrs = {
        "otp": attr.label(mandatory = True, providers = [FipsOtpRuntimeInfo]),
    },
)

def _elixir_runtime_finalize_impl(ctx):
    root = _directory_named(ctx.attr.foreign[DefaultInfo].files.to_list(), "runtime")
    return [
        DefaultInfo(files = depset([root])),
        FipsElixirRuntimeInfo(root = root, version = ctx.attr.elixir_version),
    ]

_elixir_runtime_finalize = rule(
    implementation = _elixir_runtime_finalize_impl,
    attrs = {
        "foreign": attr.label(mandatory = True),
        "elixir_version": attr.string(default = ELIXIR_SOURCE.version),
    },
)

def elixir_runtime(
        name,
        bootstrap,
        otp,
        elixir_version = ELIXIR_SOURCE.version,
        visibility = None,
        tags = None):
    """Builds architecture-independent Elixir bytecode with GNU Make.

    Args:
      name: Elixir runtime target name.
      bootstrap: Label providing the native OTP bootstrap.
      otp: Label providing the target OTP runtime.
      elixir_version: Elixir version recorded in evidence.
      visibility: Optional target visibility.
      tags: Optional tags applied to generated targets.
    """
    common = {}
    if tags != None:
        common["tags"] = tags

    bootstrap_erl = name + "_bootstrap_erl"
    bootstrap_erlc = name + "_bootstrap_erlc"
    bootstrap_escript = name + "_bootstrap_escript"
    bootstrap_root = name + "_bootstrap_root"
    otp_tools = name + "_otp_tools"
    _bootstrap_artifact(name = bootstrap_erl, bootstrap = bootstrap, kind = "erl", **common)
    _bootstrap_artifact(name = bootstrap_erlc, bootstrap = bootstrap, kind = "erlc", **common)
    _bootstrap_artifact(name = bootstrap_escript, bootstrap = bootstrap, kind = "escript", **common)
    _bootstrap_artifact(name = bootstrap_root, bootstrap = bootstrap, kind = "root", **common)
    _otp_tools_artifact(name = otp_tools, otp = otp, **common)

    foreign_name = name + "_foreign"

    # Elixir has no configure step, but its launchers resolve symlinks. The
    # configure rule's in-place mode gives Make a copied source tree; the
    # pinned BusyBox `true` is the explicit no-op configure boundary.
    configure_make(
        name = foreign_name,
        args = ["-j8"],
        build_data = [
            "@fips_busybox_exec//:bin/busybox.static",
            "//fips/toolchains:foreign_perl",
            "//fips/toolchains:foreign_toolbox",
            "//fips/toolchains:foreign_toolbox_shell",
        ],
        configure_command = "VERSION",
        configure_in_place = True,
        configure_prefix = "$(execpath @fips_busybox_exec//:bin/busybox.static) true",
        data = [
            ":" + bootstrap_erl,
            ":" + bootstrap_erlc,
            ":" + bootstrap_escript,
            ":" + bootstrap_root,
            ":" + otp_tools,
        ],
        env = {
            "CONFIG_SHELL": _toolbox_shell(),
            "ERL_AFLAGS": "-pa $(execpath :%s)" % otp_tools,
            "ERL_COMPILER_OPTIONS": "deterministic",
            "HOME": "$$BUILD_TMPDIR",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "OTP_BOOTSTRAP_ROOT": "$(execpath :%s)" % bootstrap_root,
            "PATH": _foreign_path("$$(dirname $(execpath :%s))" % bootstrap_erl),
            "PERL": "$(execpath //fips/toolchains:foreign_perl)",
            "SHELL": _toolbox_shell(),
            "SOURCE_DATE_EPOCH": "0",
            "TMPDIR": "$$BUILD_TMPDIR",
        },
        install_prefix = "stage",
        lib_source = "@elixir_src//:srcs",
        out_data_dirs = ["runtime"],
        out_headers_only = True,
        out_include_dir = "",
        targets = [
            "",
            "install PREFIX=/opt/fips-elixir DESTDIR=$$BUILD_TMPDIR$$/stage/runtime",
        ],
        **common
    )

    final_args = dict(common)
    final_args.update({
        "elixir_version": elixir_version,
        "foreign": ":" + foreign_name,
    })
    if visibility != None:
        final_args["visibility"] = visibility
    _elixir_runtime_finalize(name = name, **final_args)

def _fips_boot_module_impl(ctx):
    bootstrap = ctx.attr.bootstrap[FipsOtpBootstrapInfo]
    source = ctx.file.source
    output = ctx.actions.declare_file(ctx.label.name + "/fips_boot.beam")
    ctx.actions.run(
        arguments = ["-o", output.dirname, source.path],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "OTP_BOOTSTRAP_ROOT": bootstrap.root.path,
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = bootstrap.erlc,
        execution_requirements = {"block-network": "1"},
        inputs = depset([bootstrap.root, bootstrap.erl, bootstrap.erlc, source]),
        mnemonic = "FipsBootCompile",
        outputs = [output],
        progress_message = "Compiling OpenSSL FIPS boot invariant",
    )
    return [DefaultInfo(files = depset([output]))]

fips_boot_module = rule(
    implementation = _fips_boot_module_impl,
    attrs = {
        "bootstrap": attr.label(mandatory = True, providers = [FipsOtpBootstrapInfo]),
        "source": attr.label(
            allow_single_file = [".erl"],
            default = "//runtime:fips_boot.erl",
        ),
    },
    doc = "Compiles the backend-specific OTP startup invariant without a shell action.",
)
