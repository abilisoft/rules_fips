# Repository agent instructions

## Working policy

- Work on a branch and through a pull request. Do not make feature, fix,
  documentation, CI, or cleanup changes directly on `main`.
- Treat failed validation as a defect to fix. Never weaken, bypass, or remove a
  required check merely to make CI pass.

## Rule implementation

- Implement Bazel behavior in Starlark whenever Bazel exposes the required
  primitive. Do not embed shell scripts or use shell actions as glue.
- Use a language implementation only where Starlark cannot perform the
  required runtime operation. Prefer a small, statically linked declared
  executable over a host interpreter or shell.
- If Python is unavoidable, use a declared hermetic Python toolchain and make
  Ruff, Pylint, ty, and mypy pass in their strictest supported modes. Python
  source has a 120-column limit.
- Runtime launchers must be declared, cacheable executables with complete
  runfiles. They may not discover a host interpreter, shell, loader, compiler,
  SDK, package tree, or shared library.

## Git commits

- Every commit must use the Conventional Commits format.
- Every commit must be cryptographically signed with the repository's configured Git signing identity; never create or push an unsigned commit.
- Never add `Co-authored-by`, `Signed-off-by`, `Generated-by`, AI/agent attribution, or any other commit-message trailer.
- Use only the repository's configured human Git identity for commit authorship and committer identity.
- Before pushing, verify every introduced commit's signature and audit its message for prohibited trailers and attribution text.
- Before publishing, inspect the staged file set for generated outputs,
  credentials, personal identities, and local caches. Confirm GitHub reports
  every introduced commit as verified.
- Never rewrite published history or force-push without presenting the exact
  rewrite and obtaining explicit approval.

## Repository privacy

- Do not store personal usernames, human names, personal email addresses, or identity metadata in repository files.
- Do not store machine-local absolute paths, workstation-specific configuration, or agent/runtime tool instructions in repository files.
- Git author, committer, and cryptographic signature metadata are the only identity exceptions. Project-owned contact addresses may be used where public security or support documentation requires them.
