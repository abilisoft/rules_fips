"""Bundles the official Clang 16 binaries with their declared runtime library."""

def _clang_runtime_bundle_impl(ctx):
    roots = ctx.attr.clang[DefaultInfo].files.to_list()
    if len(roots) != 1:
        fail("Clang archive must expose exactly one source directory")
    bundle = ctx.actions.declare_directory(ctx.label.name)

    command = """
set -euo pipefail

clang_root="$1"
deb="$2"
bundle="$3"
exec_root="${PWD}"
resolve_tool() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        */*) printf '%s/%s\n' "${exec_root}" "$1" ;;
        *) command -v "$1" ;;
    esac
}
clang_root="$(resolve_tool "${clang_root}")"
deb="$(resolve_tool "${deb}")"
bundle="$(resolve_tool "${bundle}")"

mkdir -p "${bundle}"
cp -RL "${clang_root}/." "${bundle}/"
runtime="${bundle}/.runtime"
mkdir -p "${runtime}" "${bundle}/lib"
dpkg-deb --extract "${deb}" "${runtime}"
libtinfo="$(find "${runtime}" -type f -name 'libtinfo.so.5.*' -print -quit)"
test -n "${libtinfo}"
cp "${libtinfo}" "${bundle}/lib/$(basename "${libtinfo}")"
ln -s "$(basename "${libtinfo}")" "${bundle}/lib/libtinfo.so.5"
rm -rf "${runtime}"

mv "${bundle}/bin/clang" "${bundle}/bin/clang.real"
printf '%s\n' \
    '#!/bin/sh' \
    'tool_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' \
    'LD_LIBRARY_PATH="${tool_root}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"' \
    'export LD_LIBRARY_PATH' \
    'exec "${tool_root}/bin/clang.real" "$@"' \
    > "${bundle}/bin/clang"
chmod 0755 "${bundle}/bin/clang"

if [ -e "${bundle}/bin/clang++" ]; then
    rm "${bundle}/bin/clang++"
fi
printf '%s\n' \
    '#!/bin/sh' \
    'tool_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)' \
    'LD_LIBRARY_PATH="${tool_root}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"' \
    'export LD_LIBRARY_PATH' \
    'exec "${tool_root}/bin/clang.real" --driver-mode=g++ "$@"' \
    > "${bundle}/bin/clang++"
chmod 0755 "${bundle}/bin/clang++"

"${bundle}/bin/clang" --version
test "$("${bundle}/bin/clang" -dumpversion)" = "16.0.0"
"""

    ctx.actions.run_shell(
        arguments = [roots[0].path, ctx.file.libtinfo_deb.path, bundle.path],
        command = command,
        env = {
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
        },
        execution_requirements = {"block-network": "1"},
        inputs = depset(
            direct = [ctx.file.libtinfo_deb],
            transitive = [ctx.attr.clang[DefaultInfo].files],
        ),
        mnemonic = "ClangRuntimeBundle",
        outputs = [bundle],
        progress_message = "Bundling Clang 16 runtime for %s" % ctx.attr.arch,
        use_default_shell_env = False,
    )

    return [DefaultInfo(files = depset([bundle]))]

clang_runtime_bundle = rule(
    implementation = _clang_runtime_bundle_impl,
    attrs = {
        "arch": attr.string(mandatory = True),
        "clang": attr.label(mandatory = True),
        "libtinfo_deb": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
    doc = "Adds the explicit libtinfo5 runtime needed by official Clang 16 binaries.",
)
