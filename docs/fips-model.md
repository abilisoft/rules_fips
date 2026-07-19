# FIPS model and claim boundary

The project builds a runtime that fails closed when its configured OpenSSL
FIPS mode is unavailable. It also records reproducible source and runtime
evidence. It does not issue a validation or compliance attestation.

## Certificate reference, not certificate inheritance

The tested provider source references the OpenSSL FIPS Provider 3.1.2 entry on
[CMVP certificate #4985](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4985).

A certificate covers a defined module, version, build procedure, mode, and set
of operational environments. Selecting related source does not automatically
extend that certificate to this repository's:

- musl build;
- CPU and kernel combination;
- static OpenSSL core;
- OTP crypto NIF;
- Elixir application;
- container image; or
- deployment procedures.

The manifests therefore use `certificate_reference`, never a field claiming
that the produced archive is validated.

## What the build checks

For the OpenSSL path, declared validators:

1. inspect the target architecture of the OpenSSL executable and provider;
2. hash the produced static libraries and provider;
3. run `openssl fipsinstall` against the packaged provider;
4. load the provider with the packaged configuration;
5. start target OTP with `-crypto fips_mode true`;
6. require `crypto:info_fips()` to report `enabled`; and
7. require OTP to report the expected provider build information.

The runtime launcher prepares the same module paths and configuration, forces
FIPS mode, and runs an Erlang guard before application code.

These checks answer “did this build behave as configured in the observed test
environment?” They do not answer “is this deployment compliant?”

## Manifest language

Every evidence manifest deliberately contains:

```json
{
  "compliance_claim": "none",
  "evidence_scope": "build-and-runtime-checks-only"
}
```

The operational-environment field is also conservative. Referencing a
certificate never causes this project to claim that its musl target is listed
on that certificate.

## Safe statements

- “The build used the source identities recorded in its manifest.”
- “The recorded OpenSSL provider source references CMVP certificate #4985.”
- “The build completed its recorded provider and OTP runtime checks.”
- “The packaged launcher requires OTP FIPS mode before user code starts.”
- “The archive does not depend on the host distribution's OpenSSL package.”

## Unsupported statements

- “This Elixir application is FIPS certified.”
- “This archive is a validated cryptographic module.”
- “The musl targets are covered by certificate #4985.”
- “Static linking preserves validation on every Linux system.”
- “Passing CI proves regulatory compliance.”

Regulated deployment owners must compare the exact module, operational
environment, application behavior, and procedures with the applicable
security policy. Vendor guidance, a compliance owner, or an accredited lab may
be required. That conclusion is outside the repository's authority.
