"""Bootstrap compiler-runtime archives without a C/C++ toolchain cycle."""

def _libssp_nonshared_impl(ctx):
    object_file = ctx.actions.declare_file(ctx.label.name + "/ssp_local.o")
    archive = ctx.actions.declare_file(ctx.label.name + "/libssp_nonshared.a")
    ctx.actions.run(
        arguments = [
            "--target=" + ctx.attr.target_triple,
            "-fPIC",
            "-fno-stack-protector",
            "-O2",
            "-c",
            ctx.file.source.path,
            "-o",
            object_file.path,
        ],
        env = {},
        executable = ctx.file.clang,
        execution_requirements = {"block-network": "1"},
        inputs = [ctx.file.source],
        mnemonic = "CompilerRuntimeCompile",
        outputs = [object_file],
        progress_message = "Compiling declared {} compiler runtime".format(ctx.attr.target_triple),
        tools = [ctx.attr.toolchain[DefaultInfo].files],
    )
    ctx.actions.run(
        arguments = ["rcsD", archive.path, object_file.path],
        env = {},
        executable = ctx.file.ar,
        execution_requirements = {"block-network": "1"},
        inputs = [object_file],
        mnemonic = "CompilerRuntimeArchive",
        outputs = [archive],
        progress_message = "Archiving declared {} compiler runtime".format(ctx.attr.target_triple),
        tools = [ctx.attr.toolchain[DefaultInfo].files],
    )
    return [DefaultInfo(files = depset([archive]))]

libssp_nonshared = rule(
    implementation = _libssp_nonshared_impl,
    attrs = {
        "ar": attr.label(allow_single_file = True, mandatory = True, cfg = "exec"),
        "clang": attr.label(allow_single_file = True, mandatory = True, cfg = "exec"),
        "source": attr.label(
            allow_single_file = [".c"],
            default = "//fips/private:ssp_local.c",
        ),
        "target_triple": attr.string(mandatory = True),
        "toolchain": attr.label(mandatory = True, cfg = "exec"),
    },
    doc = "Builds the architecture-only libssp_nonshared compiler shim with declared LLVM tools.",
)
