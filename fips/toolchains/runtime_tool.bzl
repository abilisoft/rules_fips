"""Shell-free wrappers for dynamically linked execution tools."""

load("//fips:providers.bzl", "FipsPlatformInfo", "HermeticRuntimeEnvironmentInfo")

def _project_runtime_libraries(ctx):
    projected = []
    basenames = {}
    for file in ctx.files.library_files:
        if file.basename in basenames:
            fail("supplemental runtime libraries {} and {} share basename '{}'".format(
                basenames[file.basename],
                file,
                file.basename,
            ))
        basenames[file.basename] = file
        output = ctx.actions.declare_file(ctx.label.name + "_runtime_libraries/" + file.basename)
        ctx.actions.symlink(output = output, target_file = file)
        projected.append(output)
    return projected

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
    if ctx.attr.fully_static and (ctx.files.library_files or ctx.attr.relative_library_dirs):
        fail("fully_static runtime tools must not declare dynamic library inputs")
    projected_libraries = _project_runtime_libraries(ctx)
    loader = None
    library_path = ""
    if not ctx.attr.fully_static:
        loader, library_path = _runtime_library_path(
            platform,
            ctx.executable.program,
            projected_libraries,
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
    path = []
    path_environment_names = []
    if HermeticRuntimeEnvironmentInfo in ctx.attr.data:
        runtime_environment = ctx.attr.data[HermeticRuntimeEnvironmentInfo]
        for name in sorted(runtime_environment.path_lists):
            paths = runtime_environment.path_lists[name]
            if not paths:
                fail("runtime environment path list {} must not be empty".format(name))
            if name == "PATH":
                path.extend(paths)
            else:
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
    for target in ctx.attr.path_tools:
        executable = target[DefaultInfo].files_to_run.executable
        if executable == None:
            fail("runtime PATH tool {} does not expose an executable".format(target.label))
        if executable.dirname not in path:
            path.append(executable.dirname)
    if path:
        environment.append("PATH={}\n".format(":".join(path)))
        if "PATH" not in path_environment_names:
            path_environment_names.append("PATH")
    fixed_arguments = [
        ctx.expand_location(argument, targets = ctx.attr.fixed_arg_files)
        for argument in ctx.attr.fixed_args
    ]
    for argument in fixed_arguments:
        if "\n" in argument or "\r" in argument:
            fail("fixed_args entries must not contain newline or carriage return")
    if path_environment_names:
        environment.append("RULES_FIPS_RUNTIME_PATH_ENVIRONMENT={}\n".format(
            ",".join(path_environment_names),
        ))
    ctx.actions.write(
        output = sidecar,
        content = "".join(([
            "RULES_FIPS_RUNTIME_STATIC_PROGRAM=true\n",
        ] if ctx.attr.fully_static else [
            "RULES_FIPS_RUNTIME_LOADER={}\n".format(loader.path),
            "RULES_FIPS_RUNTIME_LIBRARY_PATH={}\n".format(library_path),
        ]) + [
            "RULES_FIPS_RUNTIME_PROGRAM={}\n".format(ctx.executable.program.path),
            "RULES_FIPS_RUNTIME_FIXED_ARG_COUNT={}\n".format(len(fixed_arguments)),
        ] + [
            "RULES_FIPS_RUNTIME_FIXED_ARG_{}={}\n".format(index, argument)
            for index, argument in enumerate(fixed_arguments)
        ] + environment),
    )
    transitive = [
        ctx.attr.data[DefaultInfo].files,
        ctx.attr.launcher[DefaultInfo].files,
        ctx.attr.launcher[DefaultInfo].default_runfiles.files,
        ctx.attr.program[DefaultInfo].files,
        ctx.attr.program[DefaultInfo].default_runfiles.files,
    ]
    if not ctx.attr.fully_static:
        transitive.append(platform.libc_runtime_files)
    for target in ctx.attr.fixed_arg_files:
        transitive.extend([
            target[DefaultInfo].files,
            target[DefaultInfo].default_runfiles.files,
        ])
    for target in ctx.attr.path_tools:
        transitive.extend([
            target[DefaultInfo].files,
            target[DefaultInfo].default_runfiles.files,
        ])
    files = depset(
        direct = [wrapper, sidecar, ctx.executable.program] + projected_libraries,
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

def _runtime_tool_attrs(configuration):
    return {
        "data": attr.label(allow_files = True, cfg = configuration, mandatory = True),
        "fixed_arg_files": attr.label_list(allow_files = True, cfg = configuration),
        "fixed_args": attr.string_list(
            doc = "Ordered arguments prepended before caller arguments; $(location) expands against fixed_arg_files.",
        ),
        "fully_static": attr.bool(
            default = False,
            doc = "Execute a verified static target directly instead of passing it through the runtime loader.",
        ),
        "launcher": attr.label(mandatory = True, executable = True, cfg = configuration),
        "library_files": attr.label(allow_files = True, cfg = configuration),
        "path_tools": attr.label_list(cfg = configuration),
        "program": attr.label(allow_files = True, mandatory = True, executable = True, cfg = configuration),
        "relative_library_dirs": attr.string_list(
            doc = "Declared library directories relative to the program directory.",
        ),
        "runtime": attr.label(mandatory = True, providers = [FipsPlatformInfo], cfg = configuration),
        "variable": attr.string(),
    }

hermetic_runtime_tool = rule(
    implementation = _hermetic_runtime_tool_impl,
    attrs = _runtime_tool_attrs("exec"),
    doc = "Wraps a declared dynamic execution tool with a declared loader and runtime closure.",
    executable = True,
)

hermetic_target_runtime_tool = rule(
    implementation = _hermetic_runtime_tool_impl,
    attrs = _runtime_tool_attrs("target"),
    doc = "Wraps a target-configured dynamic executable with its declared loader and runtime closure.",
    executable = True,
)

def _hermetic_target_runtime_test_impl(ctx):
    return _hermetic_runtime_tool_impl(ctx) + [testing.ExecutionInfo({"block-network": "1"})]

hermetic_target_runtime_test = rule(
    implementation = _hermetic_target_runtime_test_impl,
    attrs = _runtime_tool_attrs("target"),
    doc = "Runs a target-configured test through its declared static or dynamic runtime closure.",
    test = True,
)
