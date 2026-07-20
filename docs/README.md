# Documentation

Start with the page that matches the question you are trying to answer.

> [!IMPORTANT]
> This repository publishes a crypto SDK rule set, not an OTP/Elixir runtime.
> See [Publishing](publishing.md) for the current release state.

| Question | Read |
| --- | --- |
| What is built, and where are the trust boundaries? | [Architecture](architecture.md) |
| What may this project truthfully say about FIPS? | [FIPS model](fips-model.md) |
| What must a consumer package at runtime? | [Portability](portability.md) |
| How do I select or override OpenSSL versions? | [Selecting versions](versions.md) |
| How are versions, checksums, and certificate references updated? | [Maintenance](maintenance.md) |
| How is a signed release prepared and later submitted to BCR? | [Publishing](publishing.md) |
| How should an AI coding agent inspect or change the repository? | [AI agent guide](agents/README.md) |

For the shortest path to a build, use the [root README](../README.md). For a
small, practical contribution checklist, use [CONTRIBUTING](../CONTRIBUTING.md).

## Project vocabulary

- **Certificate reference** identifies the CMVP certificate whose public
  documentation informed a source and build configuration. It is not a claim
  about the resulting SDK or a consumer application.
- **Evidence manifest** records pins, hashes, linkage, and checks performed by
  the build. It is not a certificate or compliance attestation.
- **Activation** means the producer-defined native tool performs the required
  per-deployment provider setup before a consumer process starts.
- **Normalized SDK** means build files, deployment files, launch tools, and
  environment templates have explicit ownership. It does not mean one output
  works across CPU architectures or every kernel.
