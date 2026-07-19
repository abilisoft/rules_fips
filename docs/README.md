# Documentation

Start with the page that matches the question you are trying to answer.

| Question | Read |
| --- | --- |
| What is built, and where are the trust boundaries? | [Architecture](architecture.md) |
| What may this project truthfully say about FIPS? | [FIPS model](fips-model.md) |
| Will the archive run on my Linux system? | [Portability](portability.md) |
| How do I select or override OpenSSL versions? | [Selecting versions](versions.md) |
| How are versions, checksums, and certificate references updated? | [Maintenance](maintenance.md) |
| How should an AI coding agent inspect or change the repository? | [AI agent guide](agents/README.md) |

For the shortest path to a build, use the [root README](../README.md). For a
small, practical contribution checklist, use [CONTRIBUTING](../CONTRIBUTING.md).

## Project vocabulary

- **Certificate reference** identifies the CMVP certificate whose public
  documentation informed a source and build configuration. It is not a claim
  about the resulting archive.
- **Evidence manifest** records pins, hashes, linkage, and checks performed by
  the build. It is not a certificate or compliance attestation.
- **Enforcement** means the launcher and boot guard require OTP FIPS mode and
  fail closed when their runtime checks fail.
- **Portable archive** means the runtime carries its target userspace
  dependencies and can be relocated as one tree. It does not mean one binary
  works across CPU architectures or every kernel.
