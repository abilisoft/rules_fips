# Contributing

Thanks for improving `rules_fips`.

Before changing behavior, read the [FIPS claim boundary](docs/fips-model.md).
Use upstream build options, keep OpenSSL as the sole backend, and do not add
source patches, compatibility shims, repository shell scripts, binaries,
credentials, identities, or machine-local paths.

Run checks proportional to the change:

```console
go test ./tools/...
bazel query //...
```

For build-rule or toolchain changes, also analyze and build the affected AMD64
and Arm64 targets. A cross-compiled Arm64 archive is not a native Arm64 runtime
test. If module resolution changed, refresh the generated lockfile with:

```console
bazel mod deps --lockfile_mode=update
```

Keep pull requests focused. Include the commands actually run and any skipped
platforms or runtime checks. Commits must be signed and use
[Conventional Commits](https://www.conventionalcommits.org/).

Do not describe a passing build as certified, validated, approved, or
compliant. Report vulnerabilities through [SECURITY](SECURITY.md), not a
public issue.
