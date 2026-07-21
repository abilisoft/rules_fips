"""Verified repository rules for immutable rules_fips inputs."""

_TREE_BUILD = """filegroup(
    name = "sysroot",
    srcs = ["."],
    visibility = ["//visibility:public"],
)
"""

def validate_extracted_tree(repository_ctx, root = "."):
    """Reject symlinks whose resolved target is outside an extracted tree.

    Args:
      repository_ctx: Active repository context after extraction.
      root: Repository-relative root of the extracted tree.
    """
    root = repository_ctx.path(root)
    root_path = str(root)
    pending = [root]
    for _depth in range(256):
        if not pending:
            return
        next_pending = []
        for directory in pending:
            for entry in directory.readdir(watch = "no"):
                entry_path = str(entry)
                if not entry.exists:
                    fail("extracted archive contains a dangling symlink: %s" % entry_path.removeprefix(root_path + "/"))
                resolved = str(entry.realpath)
                if resolved != entry_path:
                    if resolved != root_path and not resolved.startswith(root_path + "/"):
                        fail("extracted archive symlink escapes its checksum-pinned repository: %s -> %s" % (
                            entry_path.removeprefix(root_path + "/"),
                            resolved,
                        ))
                elif entry.is_dir:
                    next_pending.append(entry)
        pending = next_pending
    fail("extracted archive directory nesting exceeds 256 levels")

def validate_sha256(name, sha256):
    """Validate a lowercase SHA-256 digest before repository download.

    Args:
      name: Repository or source name used in diagnostics.
      sha256: Digest text to validate.
    """
    if len(sha256) != 64:
        fail("source %s must use a 64-character SHA-256 digest" % name)
    for index in range(len(sha256)):
        if sha256[index] not in "0123456789abcdef":
            fail("source %s SHA-256 digest must use lowercase hexadecimal" % name)

def validate_relative_path(name, value, description, allow_empty = False):
    """Validate repository extraction paths without host-relative semantics.

    Args:
      name: Repository or source name used in diagnostics.
      value: Path text to validate.
      description: Human-readable field name used in diagnostics.
      allow_empty: Whether an omitted optional path is valid.
    """
    if not value:
        if allow_empty:
            return
        fail("source %s must provide a non-empty %s" % (name, description))
    if value.startswith("/") or "\\" in value:
        fail("source %s %s must be a normalized relative path" % (name, description))
    components = value.split("/")
    if "" in components or "." in components or ".." in components:
        fail("source %s %s must be a normalized relative path" % (name, description))

def _validate_download(repository_ctx):
    validate_sha256(repository_ctx.name, repository_ctx.attr.sha256)
    validate_relative_path(
        repository_ctx.name,
        repository_ctx.attr.strip_prefix,
        "strip prefix",
        allow_empty = True,
    )
    if not repository_ctx.attr.urls:
        fail("source %s must provide at least one URL" % repository_ctx.name)
    for url in repository_ctx.attr.urls:
        if not url.startswith("https://"):
            fail("source %s URL must use HTTPS: %s" % (repository_ctx.name, url))

def _verified_archive_impl(repository_ctx):
    _validate_download(repository_ctx)
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
        type = repository_ctx.attr.type,
        canonical_id = "rules_fips:%s:%s" % (repository_ctx.name, repository_ctx.attr.sha256),
    )
    if repository_ctx.attr.retain_path and repository_ctx.attr.retain_paths:
        fail("source %s cannot set both retain_path and retain_paths" % repository_ctx.name)
    retained_paths = repository_ctx.attr.retain_paths
    if repository_ctx.attr.retain_path:
        retained_paths = [repository_ctx.attr.retain_path]
    if retained_paths:
        for path in retained_paths:
            validate_relative_path(repository_ctx.name, path, "retained archive path")
            retained = repository_ctx.path(path)
            if not retained.exists:
                fail("source %s retained archive path does not exist: %s" % (repository_ctx.name, path))

        pending = [struct(directory = repository_ctx.path("."), relative = "")]
        for _depth in range(256):
            if not pending:
                break
            next_pending = []
            for item in pending:
                for entry in item.directory.readdir(watch = "no"):
                    relative = entry.basename if not item.relative else item.relative + "/" + entry.basename
                    keep_entire = False
                    keep_parent = False
                    for path in retained_paths:
                        if relative == path or relative.startswith(path + "/"):
                            keep_entire = True
                        elif path.startswith(relative + "/"):
                            keep_parent = True
                    if keep_entire:
                        continue
                    if keep_parent and entry.is_dir:
                        next_pending.append(struct(directory = entry, relative = relative))
                    else:
                        repository_ctx.delete(entry)
            pending = next_pending
        if pending:
            fail("source %s retained archive nesting exceeds 256 levels" % repository_ctx.name)
    for path in repository_ctx.attr.remove_paths:
        validate_relative_path(repository_ctx.name, path, "removed archive path")
        repository_ctx.delete(path)
    validate_extracted_tree(repository_ctx)
    if repository_ctx.attr.build_file and repository_ctx.attr.build_file_content:
        fail("source %s cannot set both build_file and build_file_content" % repository_ctx.name)
    if repository_ctx.attr.build_file:
        repository_ctx.symlink(repository_ctx.attr.build_file, "BUILD.bazel")
    elif repository_ctx.attr.build_file_content:
        repository_ctx.file("BUILD.bazel", repository_ctx.attr.build_file_content, executable = False)
    else:
        fail("source %s requires build_file or build_file_content" % repository_ctx.name)

verified_archive = repository_rule(
    implementation = _verified_archive_impl,
    attrs = {
        "type": attr.string(),
        "build_file": attr.label(allow_single_file = True),
        "build_file_content": attr.string(),
        "remove_paths": attr.string_list(),
        "retain_path": attr.string(),
        "retain_paths": attr.string_list(),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "urls": attr.string_list(mandatory = True),
    },
)

def _verified_tree_archive_impl(repository_ctx):
    _validate_download(repository_ctx)
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        output = "sysroot",
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
        type = repository_ctx.attr.type,
        canonical_id = "rules_fips:%s:%s" % (repository_ctx.name, repository_ctx.attr.sha256),
    )
    validate_extracted_tree(repository_ctx, root = "sysroot")
    repository_ctx.file("sysroot/BUILD.bazel", _TREE_BUILD, executable = False)

verified_tree_archive = repository_rule(
    implementation = _verified_tree_archive_impl,
    attrs = {
        "type": attr.string(),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "urls": attr.string_list(mandatory = True),
    },
)
