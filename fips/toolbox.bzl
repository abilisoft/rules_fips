"""Hermetic execution tools for unavoidable upstream foreign-build scripts."""

load(
    "//fips:providers.bzl",
    "ForeignToolboxInfo",
    "HermeticMakeInfo",
    "MuslSysrootInfo",
)

_PERL_TOOLCHAIN = "@rules_perl//perl:exec_toolchain_type"

_BUSYBOX_APPLETS = [
    "arch",
    "awk",
    "basename",
    "bc",
    "cat",
    "chmod",
    "cksum",
    "cmp",
    "comm",
    "cp",
    "cut",
    "date",
    "dd",
    "df",
    "diff",
    "dirname",
    "du",
    "egrep",
    "env",
    "expr",
    "false",
    "fgrep",
    "find",
    "getopt",
    "grep",
    "groups",
    "gunzip",
    "gzip",
    "head",
    "hostid",
    "hostname",
    "id",
    "install",
    "kill",
    "killall",
    "ln",
    "ls",
    "md5sum",
    "mkdir",
    "mktemp",
    "mv",
    "nproc",
    "nice",
    "nl",
    "od",
    "paste",
    "printenv",
    "ps",
    "pwd",
    "readlink",
    "realpath",
    "rm",
    "rmdir",
    "sed",
    "seq",
    "sha256sum",
    "sh",
    "sleep",
    "sort",
    "stat",
    "strings",
    "stty",
    "sum",
    "tail",
    "tar",
    "tee",
    "touch",
    "tr",
    "true",
    "tty",
    "uname",
    "uniq",
    "wc",
    "which",
    "whoami",
    "xargs",
    "xxd",
    "xzcat",
]

def _single_tree(target, description):
    files = target[DefaultInfo].files
    roots = files.to_list()
    if len(roots) != 1:
        fail("%s must expose exactly one directory" % description)
    return roots[0], files

def _hermetic_make_impl(ctx):
    go_root, go_files = _single_tree(ctx.attr._go, "pinned Go archive")
    musl = ctx.attr._musl[MuslSysrootInfo]
    output = ctx.actions.declare_file(ctx.label.name + "/bin/make")
    go_state = ctx.actions.declare_directory(ctx.label.name + "/go_state")
    linker_values = " ".join([
        "-s",
        "-w",
        "-X main.loaderPath=" + musl.loader.path,
        "-X main.libraryPath=" + musl.libc.dirname,
        "-X main.makePath=" + ctx.file._make.path,
    ])
    ctx.actions.run(
        arguments = [
            "build",
            "-trimpath",
            "-ldflags=" + linker_values,
            "-o",
            output.path,
            ctx.file._source.path,
        ],
        env = {
            "CGO_ENABLED": "0",
            "GOCACHE": "/proc/self/cwd/" + go_state.path + "/cache",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": "amd64",
            "GOPATH": "/proc/self/cwd/" + go_state.path + "/path",
            "GOTOOLCHAIN": "local",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = go_root.path + "/bin/go",
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [ctx.file._make, ctx.file._source, musl.libc, musl.loader],
            transitive = [go_files],
        ),
        mnemonic = "HermeticMakeLauncherCompile",
        outputs = [output, go_state],
        progress_message = "Compiling static launcher for pinned GNU make 4.4.1",
    )
    runtime_files = depset([output, ctx.file._make, musl.libc, musl.loader])
    return [
        DefaultInfo(executable = output, files = runtime_files),
        HermeticMakeInfo(
            binary = output,
            files = runtime_files,
            version = "4.4.1",
        ),
    ]

hermetic_make = rule(
    implementation = _hermetic_make_impl,
    attrs = {
        "_go": attr.label(default = "@fips_go_amd64//sysroot:sysroot"),
        "_make": attr.label(
            allow_single_file = True,
            default = "@fips_make_exec//:usr/bin/make",
        ),
        "_musl": attr.label(
            default = "//fips/toolchains:musl_amd64",
            providers = [MuslSysrootInfo],
        ),
        "_source": attr.label(
            allow_single_file = [".go"],
            default = "//tools/hermetic_make:main.go",
        ),
    },
    doc = "Builds a static exec-platform launcher around pinned GNU make and musl.",
    executable = True,
)

def _host_go_tool_impl(ctx):
    go_root, go_files = _single_tree(ctx.attr._go, "pinned Go archive")
    output = ctx.actions.declare_file(ctx.label.name)
    go_state = ctx.actions.declare_directory(ctx.label.name + "_go_state")
    ctx.actions.run(
        arguments = [
            "build",
            "-trimpath",
            "-ldflags=-s -w",
            "-o",
            output.path,
            ctx.file.source.path,
        ],
        env = {
            "CGO_ENABLED": "0",
            "GOCACHE": "/proc/self/cwd/" + go_state.path + "/cache",
            "GOENV": "off",
            "GOFLAGS": "-buildvcs=false",
            "GOOS": "linux",
            "GOARCH": "amd64",
            "GOPATH": "/proc/self/cwd/" + go_state.path + "/path",
            "GOTOOLCHAIN": "local",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = go_root.path + "/bin/go",
        execution_requirements = {"block-network": "1"},
        inputs = depset(direct = [ctx.file.source], transitive = [go_files]),
        mnemonic = "HostGoToolCompile",
        outputs = [output, go_state],
        progress_message = "Compiling hermetic host tool %s" % ctx.label.name,
    )
    return [DefaultInfo(executable = output, files = depset([output]))]

host_go_tool = rule(
    implementation = _host_go_tool_impl,
    attrs = {
        "_go": attr.label(default = "@fips_go_amd64//sysroot:sysroot"),
        "source": attr.label(allow_single_file = [".go"], mandatory = True),
    },
    doc = "Builds a static amd64 execution tool using the integrity-pinned Go archive.",
    executable = True,
)

def _foreign_toolbox_impl(ctx):
    perl = ctx.toolchains[_PERL_TOOLCHAIN].perl_runtime
    make = ctx.attr.make[HermeticMakeInfo]
    applets = {}
    for applet in _BUSYBOX_APPLETS:
        output = ctx.actions.declare_file(ctx.label.name + "/bin/" + applet)
        ctx.actions.symlink(
            is_executable = True,
            output = output,
            target_file = ctx.file.busybox,
        )
        applets[applet] = output
    make_link = ctx.actions.declare_file(ctx.label.name + "/bin/make")
    ctx.actions.symlink(
        is_executable = True,
        output = make_link,
        target_file = make.binary,
    )
    files = depset(
        direct = [ctx.file.busybox, make_link] + applets.values(),
        transitive = [make.files, perl.runtime],
    )
    return [
        DefaultInfo(files = files),
        ForeignToolboxInfo(
            bin_dir = applets["sh"].dirname,
            busybox = ctx.file.busybox,
            files = files,
            make = make_link,
            perl = perl.interpreter,
            sh = applets["sh"],
        ),
    ]

foreign_toolbox = rule(
    implementation = _foreign_toolbox_impl,
    attrs = {
        "busybox": attr.label(
            allow_single_file = True,
            default = "@fips_busybox_exec//:bin/busybox.static",
        ),
        "make": attr.label(
            default = "//fips/toolchains:hermetic_make",
            providers = [HermeticMakeInfo],
        ),
    },
    doc = "Exposes only integrity-pinned shell, coreutils, make, and Perl inputs.",
    toolchains = [_PERL_TOOLCHAIN],
)

def foreign_action_environment(toolbox, extra = {}):
    """Returns a strict environment for an explicit foreign-build action."""
    environment = {
        "CONFIG_SHELL": "/proc/self/cwd/" + toolbox.sh.path,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "MAKE": "/proc/self/cwd/" + toolbox.make.path,
        "PATH": ":".join([
            "/proc/self/cwd/" + toolbox.bin_dir,
            "/proc/self/cwd/" + toolbox.perl.dirname,
        ]),
        "PERL": "/proc/self/cwd/" + toolbox.perl.path,
        "SHELL": "/proc/self/cwd/" + toolbox.sh.path,
        "SOURCE_DATE_EPOCH": "0",
    }
    environment.update(extra)
    return environment

def _foreign_perl_impl(ctx):
    runtime = ctx.toolchains[_PERL_TOOLCHAIN].perl_runtime
    executable = ctx.actions.declare_file(ctx.label.name + "/bin/perl")
    ctx.actions.symlink(
        is_executable = True,
        output = executable,
        target_file = runtime.interpreter,
    )
    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable]),
            runfiles = ctx.runfiles(transitive_files = runtime.runtime),
        ),
    ]

foreign_perl = rule(
    implementation = _foreign_perl_impl,
    doc = "Exposes the registered relocatable Perl as a rules_foreign_cc build tool.",
    executable = True,
    toolchains = [_PERL_TOOLCHAIN],
)
