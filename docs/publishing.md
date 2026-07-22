# Publishing

[Documentation home](README.md) · [Architecture](architecture.md) ·
[FIPS model](fips-model.md)

The deliverable is the `rules_fips` Bazel module. Building the module may
produce architecture-specific SDK artifacts, but GitHub/BCR publication does
not publish a language runtime or certify, validate, approve, or guarantee the
FIPS compliance of an application or deployment.

## Current publication state

[`v0.3.6`](https://github.com/abilisoft/rules_fips/tree/v0.3.6) is the current
GitHub release. Registry publication is intentionally deferred. The signed tag
identifies the source archive; it does not create a BCR entry. The **Release**
workflow creates the corresponding GitHub release page.

The **Publish to BCR** workflow is manual-only. Creating or pushing a release
tag cannot dispatch it.

## Consume before BCR

Until a BCR entry exists, declare the released module version and override it with the full
commit referenced by the verified signed tag:

```starlark
bazel_dep(
    name = "rules_fips",
    version = "0.3.6",
)

git_override(
    module_name = "rules_fips",
    remote = "https://github.com/abilisoft/rules_fips.git",
    commit = "<full peeled commit ID for v0.3.6>",
)
```

Resolve and verify the annotated tag before copying its peeled commit ID:

```console
git fetch https://github.com/abilisoft/rules_fips.git tag v0.3.6
git verify-tag FETCH_HEAD
git rev-parse FETCH_HEAD^{}
```

For a later release, replace both the declared version and commit. Never track
a branch or a tag name in `git_override`.

## Bazel Central Registry release

The checked-in BCR templates describe the signed GitHub tag archive. BCR
presubmit runs the standalone consumer module under `e2e/bcr` with Bazel 9 for
Linux AMD64 and Arm64. Its smoke target resolves the public
Starlark API without compiling OpenSSL. Full AMD64/Arm64 SDK builds and provider
checks remain separate required CI gates.

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
git tag -s v0.3.6 -m "rules_fips v0.3.6"
git push origin v0.3.6
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

## SDK artifacts

SDK artifacts remain Bazel outputs, not GitHub release assets. AMD64 and Arm64
are separate artifacts and must pass their own build/provider checks. Evidence
records inputs and observations; it is not a compliance attestation. See
[Portability](portability.md) and the [FIPS model](fips-model.md) before
distributing a consumer built from the SDK.
