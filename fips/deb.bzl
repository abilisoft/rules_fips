"""Hermetic Debian archive extraction for pinned LLVM runtime dependencies."""

def _single_tree(target, description):
    files = target[DefaultInfo].files.to_list()
    if len(files) != 1:
        fail("%s must expose exactly one directory" % description)
    return files[0], target[DefaultInfo].files

def _deb_archive_impl(ctx):
    cmake_root, cmake_files = _single_tree(ctx.attr.cmake, "pinned CMake archive")
    go_root, go_files = _single_tree(ctx.attr.go, "pinned Go archive")
    cmake = cmake_root.path + "/bin/cmake"
    go = go_root.path + "/bin/go"

    extractor = ctx.actions.declare_file(ctx.label.name + "_tools/deb_ar_extract")
    go_state = ctx.actions.declare_directory(ctx.label.name + "_tools/go_state")
    ctx.actions.run(
        arguments = [
            "build",
            "-trimpath",
            "-o",
            extractor.path,
            ctx.file.extractor_source.path,
        ],
        env = {
            "GOCACHE": "/proc/self/cwd/" + go_state.path + "/cache",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": ctx.attr.goarch,
            "GOPATH": "/proc/self/cwd/" + go_state.path + "/path",
            "GOTOOLCHAIN": "local",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = go,
        execution_requirements = {"block-network": "1"},
        inputs = depset(direct = [ctx.file.extractor_source], transitive = [go_files]),
        mnemonic = "DebExtractorCompile",
        outputs = [extractor, go_state],
        progress_message = "Compiling hermetic Debian archive extractor",
    )

    root = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run(
        arguments = [ctx.file.deb.path, root.path, cmake],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = extractor,
        execution_requirements = {"block-network": "1"},
        inputs = depset(direct = [ctx.file.deb, extractor], transitive = [cmake_files]),
        mnemonic = "DebArchiveExtract",
        outputs = [root],
        progress_message = "Extracting pinned Debian package %s" % ctx.file.deb.basename,
    )
    return [DefaultInfo(files = depset([root]))]

deb_archive = rule(
    implementation = _deb_archive_impl,
    attrs = {
        "cmake": attr.label(mandatory = True),
        "deb": attr.label(allow_single_file = [".deb"], mandatory = True),
        "extractor_source": attr.label(
            allow_single_file = [".go"],
            default = "//tools/deb_ar_extract:main.go",
        ),
        "go": attr.label(mandatory = True),
        "goarch": attr.string(mandatory = True, values = ["amd64", "arm64"]),
    },
    doc = "Extracts a SHA-pinned .deb without host dpkg/ar/tar tools.",
)
