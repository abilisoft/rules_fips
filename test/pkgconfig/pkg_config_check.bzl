"""Focused execution check for a declared target pkg-config SDK."""

load("//fips:providers.bzl", "TargetPkgConfigSdkInfo")

def _pkg_config_sdk_check_impl(ctx):
    sdk = ctx.attr.sdk[TargetPkgConfigSdkInfo]
    audit_log = ctx.actions.declare_file(ctx.label.name + ".log")
    ctx.actions.run(
        arguments = [
            "--log-file=" + audit_log.path,
            "--exists",
            ctx.attr.package,
        ],
        env = {
            "PATH": "",
            "PKG_CONFIG_ALLOW_CROSS": "1",
            "PKG_CONFIG_LIBDIR": ":".join(sdk.libdirs),
            "PKG_CONFIG_PATH": "",
            "PKG_CONFIG_SYSROOT_DIR": sdk.sysroot,
            "PKG_CONFIG_SYSTEM_INCLUDE_PATH": "",
            "PKG_CONFIG_SYSTEM_LIBRARY_PATH": "",
        },
        executable = sdk.pkg_config,
        execution_requirements = {"block-network": "1"},
        inputs = sdk.files,
        mnemonic = "PkgConfigSdkCheck",
        outputs = [audit_log],
        progress_message = "Checking declared pkg-config SDK %{label}",
    )
    return [DefaultInfo(files = depset([audit_log]))]

pkg_config_sdk_check = rule(
    implementation = _pkg_config_sdk_check_impl,
    attrs = {
        "package": attr.string(mandatory = True),
        "sdk": attr.label(
            mandatory = True,
            providers = [TargetPkgConfigSdkInfo],
        ),
    },
)
