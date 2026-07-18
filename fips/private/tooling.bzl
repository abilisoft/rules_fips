"""Toolchain access helpers shared by rules_fips actions."""

load(
    "@rules_cc//cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
    "CPP_LINK_EXECUTABLE_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cpp_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

CMAKE_TOOLCHAIN = "@rules_foreign_cc//toolchains:cmake_toolchain"
MAKE_TOOLCHAIN = "@rules_foreign_cc//toolchains:make_toolchain"
NINJA_TOOLCHAIN = "@rules_foreign_cc//toolchains:ninja_toolchain"
CC_TOOLCHAINS = use_cc_toolchain()

def foreign_tool(ctx, toolchain_type):
    data = ctx.toolchains[toolchain_type].data
    inputs = depset()
    path = data.path
    if data.target:
        inputs = data.target[DefaultInfo].files
        for file in inputs.to_list():
            if file.path == data.path or file.path.endswith("/" + data.path):
                path = file.path
                break
    return struct(
        env = data.env,
        inputs = inputs,
        path = path,
    )

def cc_tools(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    c_variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        user_compile_flags = ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts,
    )
    cxx_variables = cc_common.create_compile_variables(
        add_legacy_cxx_options = True,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        user_compile_flags = ctx.fragments.cpp.copts + ctx.fragments.cpp.cxxopts,
    )
    link_variables = cc_common.create_link_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        is_linking_dynamic_library = False,
        is_using_linker = True,
        must_keep_debug = False,
        user_link_flags = ctx.fragments.cpp.linkopts,
    )
    return struct(
        cc = cc_common.get_tool_for_action(
            action_name = C_COMPILE_ACTION_NAME,
            feature_configuration = feature_configuration,
        ),
        cxx = cc_common.get_tool_for_action(
            action_name = CPP_COMPILE_ACTION_NAME,
            feature_configuration = feature_configuration,
        ),
        cflags = cc_common.get_memory_inefficient_command_line(
            action_name = C_COMPILE_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = c_variables,
        ),
        cxxflags = cc_common.get_memory_inefficient_command_line(
            action_name = CPP_COMPILE_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = cxx_variables,
        ),
        inputs = cc_toolchain.all_files,
        linkflags = cc_common.get_memory_inefficient_command_line(
            action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
            feature_configuration = feature_configuration,
            variables = link_variables,
        ),
    )
