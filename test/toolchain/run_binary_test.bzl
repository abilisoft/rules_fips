"""Shell-free execution test for a declared binary and its runfiles."""

def _run_binary_test_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable.binary,
        is_executable = True,
    )
    binary_info = ctx.attr.binary[DefaultInfo]
    return [
        DefaultInfo(
            executable = executable,
            runfiles = ctx.runfiles().merge(binary_info.default_runfiles).merge(binary_info.data_runfiles),
        ),
        testing.ExecutionInfo({"block-network": "1"}),
    ]

run_binary_test = rule(
    implementation = _run_binary_test_impl,
    attrs = {
        "binary": attr.label(
            cfg = "target",
            executable = True,
            mandatory = True,
        ),
    },
    test = True,
)
