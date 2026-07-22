"""Native template expansion for upstream configure headers."""

def _configure_header_impl(ctx):
    output = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.expand_template(
        output = output,
        substitutions = ctx.attr.substitutions,
        template = ctx.file.template,
    )
    return [DefaultInfo(files = depset([output]))]

configure_header = rule(
    implementation = _configure_header_impl,
    attrs = {
        "out": attr.string(mandatory = True),
        "substitutions": attr.string_dict(mandatory = True),
        "template": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
    doc = "Expands an upstream configure template without a shell action.",
)
