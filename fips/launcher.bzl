"""Static target launchers that enforce FIPS startup invariants."""

load("//fips:providers.bzl", "FipsLauncherInfo")

_TOOLCHAIN_TYPE = "//fips:toolchain_type"

def _fips_launcher_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    launcher = ctx.actions.declare_file(ctx.label.name)
    go_state = ctx.actions.declare_directory(ctx.label.name + "_go_state")
    goarch = "amd64" if platform.arch == "amd64" else "arm64"
    ctx.actions.run(
        arguments = [
            "build",
            "-trimpath",
            "-ldflags=-s -w -X main.backend=%s -X main.elixirVersion=%s" % (
                ctx.attr.backend,
                ctx.attr.elixir_version,
            ),
            "-o",
            launcher.path,
            ctx.file.source.path,
        ],
        env = {
            "CGO_ENABLED": "0",
            "GOCACHE": "/proc/self/cwd/" + go_state.path + "/cache",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": goarch,
            "GOPATH": "/proc/self/cwd/" + go_state.path + "/path",
            "GOTOOLCHAIN": "local",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = platform.go_bin,
        execution_requirements = {"block-network": "1"},
        inputs = depset(direct = [ctx.file.source], transitive = [platform.go_files]),
        mnemonic = "FipsLauncherCompile",
        outputs = [launcher, go_state],
        progress_message = "Compiling static %s FIPS launcher for %s" % (
            ctx.attr.backend,
            platform.arch,
        ),
    )
    return [
        DefaultInfo(executable = launcher, files = depset([launcher])),
        FipsLauncherInfo(backend = ctx.attr.backend, binary = launcher),
    ]

fips_launcher = rule(
    implementation = _fips_launcher_impl,
    attrs = {
        "backend": attr.string(mandatory = True, values = ["boringssl", "openssl"]),
        "elixir_version": attr.string(default = "1.20.2"),
        "source": attr.label(
            allow_single_file = [".go"],
            default = "//tools/fips_launcher:main.go",
        ),
    },
    doc = "Cross-compiles a shell-free static launcher for the selected FIPS backend.",
    executable = True,
    toolchains = [_TOOLCHAIN_TYPE],
)
