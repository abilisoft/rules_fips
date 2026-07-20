# Publishing

[Documentation home](README.md) · [Architecture](architecture.md) ·
[FIPS model](fips-model.md)

There are two independent deliverables:

1. the `rules_fips` Bazel module published to the Bazel Central Registry;
2. architecture-specific OTP/Elixir runtime archives produced by the rules.

Publishing the rules does not publish a runtime archive. Neither operation
certifies, validates, approves, or guarantees the FIPS compliance of an
application or deployment.

## Current publication state

Version `0.1.0` is prepared for BCR, but registry publication is intentionally
deferred. The signed GitHub tag and release identify the source archive; they
do not create a BCR entry. Until an entry exists, consumers must use the full
verified commit referenced by the signed tag rather than tracking a branch or
movable tag.

The **Publish to BCR** workflow is manual-only. Creating or pushing a release
tag cannot dispatch it.

## Bazel Central Registry release

The checked-in BCR templates describe the signed GitHub tag archive. BCR
presubmit runs the standalone consumer module under `e2e/bcr` with Bazel 9 on
Debian 13 for Linux AMD64 and Arm64. Its smoke target resolves the public
Starlark API without compiling OTP, Elixir, or OpenSSL. Full distribution
builds and runtime checks remain separate required CI gates.

For each version:

1. set `module(version = ...)` in `MODULE.bazel`;
2. refresh and validate both module lockfiles;
3. merge the release-preparation change through protected `main`;
4. create a signed annotated tag whose `v`-stripped version matches the module;
5. push the tag and let the **Release** workflow create the GitHub release;
6. when publication is authorized, run **Publish to BCR** with that tag;
7. open the manual pull-request URL printed by the workflow and wait for BCR
   validation and review.

```console
git tag -s v0.1.0 -m "rules_fips v0.1.0"
git push origin v0.1.0
```

The release workflow rejects lightweight tags, unverified tag signatures,
tags outside `main`, and a tag/module version mismatch. The BCR workflow also
requires an existing non-draft GitHub release. Its reusable publisher is
pinned by immutable revision and uses the tag archive rather than generating
repository-owned release scripts.

The BCR workflow needs `BCR_PUBLISH_TOKEN` with write access to the
`abilisoft/bazel-central-registry` fork. It deliberately sets
`open_pull_request: false`, so it pushes a proposal branch but does not open an
upstream pull request automatically.

## Runtime archives

Runtime archives remain Bazel outputs, not GitHub release assets. AMD64 and
Arm64 are separate artifacts and must pass their own build and runtime checks.
The archive evidence records inputs and observations; it is not a compliance
attestation. See [Portability](portability.md) and the
[FIPS model](fips-model.md) before distributing an archive.
