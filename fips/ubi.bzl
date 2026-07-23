"""Checksum-locked UBI RPM trees extracted without repository-time mutation."""

load("@bazeldnf//bazeldnf:defs.bzl", "rpmtree")
load("//fips:providers.bzl", "UbiRpmTreeInfo")

def _ubi_rpm_tree_impl(ctx):
    archives = ctx.attr.archive[DefaultInfo].files.to_list()
    if len(archives) != 1:
        fail("ubi_rpm_tree archive must expose exactly one tar file")

    tree = ctx.actions.declare_directory(ctx.label.name + "_tree")
    tool = ctx.executable._tar
    arguments = ["tar"]
    for path in ctx.attr.exclude_paths:
        arguments.extend(["--exclude", path])
    arguments.extend([
        "-xf",
        archives[0].path,
        "-C",
        tree.path,
    ])
    ctx.actions.run(
        executable = tool,
        arguments = arguments,
        inputs = ctx.attr.archive[DefaultInfo].files,
        outputs = [tree],
        tools = [tool],
        env = {
            "LANG": "C",
            "LC_ALL": "C",
            "TZ": "UTC",
        },
        execution_requirements = {"block-network": "1"},
        mnemonic = "UbiRpmTree",
        progress_message = "Extracting checksum-locked UBI RPM tree for {}".format(ctx.attr.arch),
        use_default_shell_env = False,
    )
    files = depset([tree])
    return [
        DefaultInfo(files = files),
        UbiRpmTreeInfo(
            arch = ctx.attr.arch,
            files = files,
            root = tree.path,
            root_short_path = tree.short_path,
            tree = tree,
        ),
    ]

_ubi_rpm_tree = rule(
    implementation = _ubi_rpm_tree_impl,
    attrs = {
        "_tar": attr.label(
            allow_files = True,
            default = Label("//fips/toolchains:busybox_exec"),
            cfg = "exec",
            executable = True,
        ),
        "arch": attr.string(mandatory = True, values = ["amd64", "arm64"]),
        "archive": attr.label(mandatory = True, allow_single_file = [".tar"]),
        "exclude_paths": attr.string_list(),
    },
)

def ubi_rpm_tree(name, arch, rpms, exclude_paths = [], symlinks = {}, visibility = None, tags = None):
    """Merges checksum-pinned RPMs and exposes their extracted filesystem tree.

    Args:
      name: Name of the generated tree target.
      arch: Target architecture, `amd64` or `arm64`.
      rpms: Labels providing the checksum-pinned RPM inputs.
      exclude_paths: Optional absolute archive paths omitted from the tree.
      symlinks: Optional normalized symlinks added by `rpmtree`.
      visibility: Optional visibility for the extracted tree target.
      tags: Optional tags applied to generated targets.
    """
    common = {}
    if tags != None:
        common["tags"] = tags
    archive = name + "_archive"
    rpmtree(
        name = archive,
        rpms = rpms,
        symlinks = symlinks,
        **common
    )
    args = dict(common)
    if visibility != None:
        args["visibility"] = visibility
    _ubi_rpm_tree(
        name = name,
        arch = arch,
        archive = ":" + archive,
        exclude_paths = exclude_paths,
        **args
    )
