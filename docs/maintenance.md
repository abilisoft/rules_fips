# Maintaining versions and evidence

An ordinary release update and a certificate-referenced provider update are
not the same operation. Keep source identity, tested status, runtime checks,
and public language synchronized.

## Sources of truth

| Data | File |
| --- | --- |
| Tested OpenSSL catalog and defaults | `fips/versions.bzl` |
| OTP, Elixir, sysroot, and other source defaults | `fips/extensions.bzl` |
| Bazel modules and build-tool archives | `MODULE.bazel` |
| Resolved source manifest | `fips/metadata.bzl` |
| OpenSSL build configuration | `fips/foreign_crypto.bzl` |
| OTP build configuration | `fips/foreign_otp.bzl` |
| Crypto and runtime evidence fields | `tools/fips_artifact_validator/main.go` and `tools/runtime_packager/main.go` |

If code, lockfile, generated manifest, and documentation disagree, the update
is incomplete.

## Updating a catalog entry

1. Read authoritative release notes, support policy, and license changes.
2. Obtain the upstream release archive and verify its digest independently.
3. Change version, URL, SHA-256, and strip prefix as one identity.
4. Confirm every build flag remains an upstream-supported option.
5. Refresh the Bzlmod lockfile:

   ```console
   bazel mod deps --lockfile_mode=update
   ```

6. Run Go tests and Bazel package analysis.
7. Build AMD64 and Arm64 crypto targets and full distributions.
8. Execute each archive on its native architecture.
9. Inspect both source and runtime evidence manifests.
10. Only then call the new entry tested or make it the default.

The checked-in `.bazelrc` uses `--lockfile_mode=error`, so normal validation
fails on a stale lockfile instead of silently rewriting it.

## Reviewing a custom version

A user's exact source override is intentionally allowed before it joins the
matrix. The build labels it `catalog_entry: false`. Do not turn a successful
custom build into a catalog entry without completing the update procedure
above.

Compatibility must be tested as a pair: the OpenSSL core and loadable provider
have distinct source identities and maintenance lifecycles.

## Certificate-referenced provider update

Before adding or changing a certificate reference, review authoritative CMVP
records and the applicable security policy. Record at least:

- module name and exact version;
- certificate number and current status;
- exact archive identity;
- documented build procedure and tool requirements;
- cryptographic module boundary;
- approved-mode controls and service indicators;
- operational environments; and
- every difference between those environments and this project's musl targets.

Then update the catalog, certificate lookup, validator expectations, manifests,
and [FIPS model](fips-model.md) in one reviewed change. If the build differs
from a security policy, record the difference. Never infer equivalence.

## Release language

Release notes and pull requests should state:

- exact versions changed;
- targets actually built or executed;
- checks that passed;
- certificate references recorded; and
- limitations or untested platforms.

They must not describe repository outputs as certified, validated, approved,
or compliant unless an independent authorized process has established that
claim for the exact produced module and operational environment.
