"""Shell-free wrappers for dynamically linked execution tools."""

load("//fips:providers.bzl", "FipsPlatformInfo", "HermeticRuntimeEnvironmentInfo")

def _runtime_library_path(platform, program, library_files, relative_library_dirs):
    directories = []
    loader = None
    for entry in platform.libc_runtime_entries:
        if entry.destination == "ld-runtime.so.1":
            loader = entry.file
        elif entry.file.dirname not in directories:
            directories.append(entry.file.dirname)
    for relative in relative_library_dirs:
        directory = program.dirname + "/" + relative
        if directory not in directories:
            directories.append(directory)
    for file in library_files:
        if file.dirname not in directories:
            directories.append(file.dirname)
    if loader == None:
        fail("runtime platform does not expose its normalized loader")
    if not directories:
        fail("runtime platform does not expose a shared-library directory")
    return loader, ":".join(directories)

def _hermetic_runtime_tool_impl(ctx):
    platform = ctx.attr.runtime[FipsPlatformInfo]
    loader, library_path = _runtime_library_path(
        platform,
        ctx.executable.program,
        ctx.files.library_files,
        ctx.attr.relative_library_dirs,
    )
    wrapper = ctx.actions.declare_file(ctx.label.name)
    sidecar = ctx.actions.declare_file(ctx.label.name + ".runtime.env")
    ctx.actions.symlink(
        output = wrapper,
        target_file = ctx.executable.launcher,
        is_executable = True,
    )
    environment = []
    path_environment_names = []
    if HermeticRuntimeEnvironmentInfo in ctx.attr.data:
        runtime_environment = ctx.attr.data[HermeticRuntimeEnvironmentInfo]
        for name in sorted(runtime_environment.path_lists):
            paths = runtime_environment.path_lists[name]
            if not paths:
                fail("runtime environment path list {} must not be empty".format(name))
            environment.append("{}={}\n".format(
                name,
                ":".join(paths),
            ))
            path_environment_names.append(name)
        for name in sorted(runtime_environment.reentry_variables):
            environment.append("{}={}\n".format(name, wrapper.path))
            path_environment_names.append(name)
        for name in sorted(runtime_environment.variables):
            environment.append("{}={}\n".format(name, runtime_environment.variables[name]))
    if ctx.attr.path_tools:
        directories = []
        for target in ctx.attr.path_tools:
            executable = target[DefaultInfo].files_to_run.executable
            if executable == None:
                fail("runtime PATH tool {} does not expose an executable".format(target.label))
            if executable.dirname not in directories:
                directories.append(executable.dirname)
        environment.append("PATH={}\n".format(":".join(directories)))
        path_environment_names.append("PATH")
    if path_environment_names:
        environment.append("RULES_FIPS_RUNTIME_PATH_ENVIRONMENT={}\n".format(
            ",".join(path_environment_names),
        ))
    ctx.actions.write(
        output = sidecar,
        content = "".join([
            "RULES_FIPS_RUNTIME_LOADER={}\n".format(loader.path),
            "RULES_FIPS_RUNTIME_LIBRARY_PATH={}\n".format(library_path),
            "RULES_FIPS_RUNTIME_PROGRAM={}\n".format(ctx.executable.program.path),
        ] + environment),
    )
    transitive = [
        ctx.attr.data[DefaultInfo].files,
        ctx.attr.launcher[DefaultInfo].files,
        ctx.attr.launcher[DefaultInfo].default_runfiles.files,
        ctx.attr.program[DefaultInfo].files,
        ctx.attr.program[DefaultInfo].default_runfiles.files,
        platform.libc_runtime_files,
    ]
    if ctx.attr.library_files:
        transitive.extend([
            ctx.attr.library_files[DefaultInfo].files,
            ctx.attr.library_files[DefaultInfo].default_runfiles.files,
        ])
    for target in ctx.attr.path_tools:
        transitive.extend([
            target[DefaultInfo].files,
            target[DefaultInfo].default_runfiles.files,
        ])
    files = depset(
        direct = [wrapper, sidecar, ctx.executable.program],
        transitive = transitive,
    )
    providers = [DefaultInfo(
        executable = wrapper,
        files = files,
        runfiles = ctx.runfiles(transitive_files = files),
    )]
    if ctx.attr.variable:
        providers.append(platform_common.TemplateVariableInfo({
            ctx.attr.variable: wrapper.path,
        }))
    return providers

hermetic_runtime_tool = rule(
    implementation = _hermetic_runtime_tool_impl,
    attrs = {
        "data": attr.label(allow_files = True, cfg = "exec", mandatory = True),
        "launcher": attr.label(mandatory = True, executable = True, cfg = "exec"),
        "library_files": attr.label(allow_files = True, cfg = "exec"),
        "path_tools": attr.label_list(cfg = "exec"),
        "program": attr.label(allow_files = True, mandatory = True, executable = True, cfg = "exec"),
        "relative_library_dirs": attr.string_list(
            doc = "Declared library directories relative to the program directory.",
        ),
        "runtime": attr.label(mandatory = True, providers = [FipsPlatformInfo], cfg = "exec"),
        "variable": attr.string(),
    },
    doc = "Wraps a declared dynamic execution tool with a declared loader and runtime closure.",
    executable = True,
)
