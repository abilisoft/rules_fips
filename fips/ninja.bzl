"""Builds the exact Ninja release named by the BoringCrypto security policy."""

load("//fips:providers.bzl", "PolicyNinjaInfo")

_TOOLCHAIN_TYPE = "//fips:toolchain_type"

def _compile_arguments(platform, source, output):
    return [
        "--target=" + platform.musl_triplet,
        "--sysroot=" + platform.sysroot_path,
        "-resource-dir=" + platform.resource_dir,
        "-B" + platform.crt_dir + "/",
        "-std=gnu++11",
        "-stdlib=libc++",
        "-isystem",
        platform.sysroot_path + "/usr/include/c++/v1",
        "-O2",
        "-DNDEBUG",
        "-fPIC",
        "-Wno-deprecated",
        "-c",
        source.path,
        "-o",
        output.path,
    ]

def _policy_ninja_impl(ctx):
    platform = ctx.toolchains[_TOOLCHAIN_TYPE].fips
    objects = []
    compile_inputs = depset(
        direct = ctx.files.headers,
        transitive = [
            platform.clang_files,
            platform.clang_runtime_files,
            platform.crt_files,
            platform.sysroot_files,
        ],
    )
    for source in ctx.files.srcs:
        output = ctx.actions.declare_file(
            ctx.label.name + "/obj/" + source.basename + ".o",
        )
        ctx.actions.run(
            arguments = _compile_arguments(platform, source, output),
            env = {
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "LD_LIBRARY_PATH": platform.clang_library_path,
                "SOURCE_DATE_EPOCH": "0",
            },
            executable = platform.clang_cxx,
            execution_requirements = {"block-network": "1"},
            inputs = depset(direct = [source], transitive = [compile_inputs]),
            mnemonic = "PolicyNinjaCompile",
            outputs = [output],
            progress_message = "Compiling Ninja 1.11.1 (%s)" % source.basename,
        )
        objects.append(output)

    binary = ctx.actions.declare_file(ctx.label.name + "/bin/ninja")
    ctx.actions.run(
        arguments = [
            "--target=" + platform.musl_triplet,
            "--sysroot=" + platform.sysroot_path,
            "-resource-dir=" + platform.resource_dir,
            "-B" + platform.crt_dir + "/",
            "--rtlib=compiler-rt",
            "--unwindlib=libunwind",
            "-fuse-ld=lld",
            "-stdlib=libc++",
            "-static",
            "-Wl,-S",
            "-Wl,-z,relro,-z,now",
        ] + [object.path for object in objects] + [
            "-lc++abi",
            "-o",
            binary.path,
        ],
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "LD_LIBRARY_PATH": platform.clang_library_path,
            "SOURCE_DATE_EPOCH": "0",
        },
        executable = platform.clang_cxx,
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = objects,
            transitive = [
                platform.clang_files,
                platform.clang_runtime_files,
                platform.crt_files,
                platform.sysroot_files,
            ],
        ),
        mnemonic = "PolicyNinjaLink",
        outputs = [binary],
        progress_message = "Linking static Ninja 1.11.1 for %s" % platform.arch,
    )

    files = depset([binary, ctx.file.license])
    return [
        DefaultInfo(files = depset([binary])),
        PolicyNinjaInfo(
            binary = binary,
            files = files,
            version = "1.11.1",
        ),
    ]

policy_ninja = rule(
    implementation = _policy_ninja_impl,
    attrs = {
        "headers": attr.label(
            default = "@ninja_1_11_1_src//:runtime_headers",
        ),
        "license": attr.label(
            allow_single_file = True,
            default = "@ninja_1_11_1_src//:COPYING",
        ),
        "srcs": attr.label(
            default = "@ninja_1_11_1_src//:runtime_srcs",
        ),
    },
    doc = "Builds a fully static Ninja 1.11.1 executable with native Bazel actions.",
    toolchains = [_TOOLCHAIN_TYPE],
)
