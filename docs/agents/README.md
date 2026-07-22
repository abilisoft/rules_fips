# AI agent guide

Use this as a task protocol for inspecting or changing `rules_fips`. It is
deliberately evidence-first: read the executable configuration, make the
smallest coherent change, and report only checks that actually ran.

## Mission

Preserve a reproducible, backend-owned OpenSSL FIPS SDK that language rule sets
can consume without turning engineering evidence into a compliance claim.

## Hard rules

1. Never call an output FIPS certified, validated, approved, or compliant.
2. Never invent versions, hashes, certificate status, operational
   environments, compatibility, target support, or test results.
3. Never add upstream source patches or compatibility shims. Exhaust documented
   configure/build options; report a real incompatibility if they are
   insufficient.
4. Do not add repository shell scripts, generated shell commands, or
   repository-owned `run_shell` actions. Starlark owns argument/environment
   construction; static helpers are reserved for unavoidable process,
   filesystem, ELF, and runtime-launch operations.
5. Do not add vendored binaries, personal identity, machine-local paths, or
   credentials.
6. Keep exact versions, URLs, SHA-256 values, strip prefixes, manifests, BCR
   templates, docs, and module lockfiles consistent.
7. Treat AMD64 and Arm64 as distinct outputs. QEMU provider execution is not a
   native-hardware result.
8. Never edit `MODULE.bazel.lock` manually.

## Read before acting

Read the smallest relevant chain:

1. `AGENTS.md` — repository policy.
2. `fips/versions.bzl` — tested OpenSSL catalog.
3. `fips/extensions.bzl` — exact source resolution and overrides.
4. `fips/defs.bzl` — public API.
5. `fips/foreign_crypto.bzl` — real OpenSSL build flags.
6. `fips/crypto_sdk.bzl` — normalized build/deployment contract.
7. `tools/fips_artifact_validator/main.go` — checks and evidence semantics.
8. The relevant human guide under `docs/`.

If prose and executable configuration disagree, do not choose the nicer story.
Fix the disagreement.

## Public API

Until the module is published to BCR, pin the full verified commit referenced
by the signed `v0.3.6` tag, following
[Publishing](../publishing.md#consume-before-bcr). Never track a branch or tag.

```starlark
load("@rules_fips//fips:defs.bzl", "openssl_fips_sdk")

openssl_fips_sdk(
    name = "crypto_sdk",
)
```

There is one crypto backend: OpenSSL. Adding another backend requires a new
explicit project decision and a clean, upstream-supported, no-patch
integration.

Catalog selection and custom source override syntax live in
[Selecting versions](../versions.md). A custom archive still requires an exact
digest and must remain marked outside the tested catalog.

## Validation ladder

Do not report a higher level than completed:

1. **Inspection** — source pins, build flags, target names, and docs agree.
2. **Go tests** — test and vet every static helper with the pinned Go version.
3. **Bazel load** — `bazel query //...`.
4. **Bazel analysis** — analyze the explicit affected target and platform.
5. **Crypto build** — build the affected `_crypto` target.
6. **SDK build** — build the full example target. The Arm64 build runs provider
   checks under pinned QEMU; report that as emulated target execution.
7. **Consumer integration** — run the downstream language/runtime matrix. Do
   not report consumer behavior as a rules_fips-owned check.

Use `--config=local` only when intentionally disabling configured remote
services. Do not imply that local execution used the digest-pinned remote
userspace.

## Task playbooks

### Build

Determine the target architecture. Build the explicit SDK or consumer target.
Report the SDK/evidence paths, target architecture, and highest completed
validation level.

### Version change

Decide whether the source is an ordinary core update or a
certificate-referenced provider update. Verify authoritative upstream facts,
change the complete source identity, update the lockfile through Bazel, and run
the affected matrix. Follow [Maintenance](../maintenance.md).

### Custom-version diagnosis

First build `//fips:source_pins` and inspect `catalog_entry`, resolved version,
URL, digest, and certificate reference. Then separate fetch, configure,
compile, provider-check, and SDK-assembly failures. Do not “solve”
incompatibility with a source patch.

### Documentation

Cross-check every version, flag, target, linkage statement, and evidence field
against code. Preserve the claim boundary in [FIPS model](../fips-model.md).

### Release preparation

Follow [Publishing](../publishing.md). Match `MODULE.bazel` to the intended
signed tag, regenerate lockfiles with Bazel, and build the standalone
`e2e/bcr` consumer. Treat that consumer as module/API evidence only; it does
not replace either architecture's SDK build and provider check. Never dispatch the
manual BCR publisher unless the user explicitly authorizes registry
publication.

## Completion report

A trustworthy report states:

- what changed;
- exact versions and target architectures affected;
- checks actually completed;
- artifacts actually produced;
- limitations, skipped execution, or external facts not verified; and
- no compliance conclusion.

“The build passed” must never become “the deployment is compliant.”
