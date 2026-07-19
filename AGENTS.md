# Repository agent instructions

## Git commits

- Every commit must use the Conventional Commits format.
- Every commit must be cryptographically signed with the repository's configured Git signing identity; never create or push an unsigned commit.
- Do not add `Co-authored-by`, `Signed-off-by`, `Generated-by`, AI/agent attribution, or any other commit-message trailer unless the user explicitly requests the exact trailer.
- Use only the repository's configured human Git identity for commit authorship and committer identity.
- Before pushing, verify every introduced commit's signature and audit its message for prohibited trailers and attribution text.

## Repository privacy

- Do not store personal usernames, human names, personal email addresses, or identity metadata in repository files.
- Do not store machine-local absolute paths, workstation-specific configuration, or agent/runtime tool instructions in repository files.
- Git author, committer, and cryptographic signature metadata are the only identity exceptions. Project-owned contact addresses may be used where public security or support documentation requires them.
