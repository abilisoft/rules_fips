"""Tested OpenSSL source catalog.

Every entry identifies immutable source bytes. Catalog membership means the
combination is exercised by this repository; it is not a compliance claim.
"""

DEFAULT_OPENSSL_CORE_VERSION = "3.5.7"
DEFAULT_OPENSSL_FIPS_PROVIDER_VERSION = "3.1.2"

OPENSSL_CORE_RELEASES = {
    "3.5.7": struct(
        sha256 = "a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8",
        strip_prefix = "openssl-3.5.7",
        urls = ["https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz"],
        version = "3.5.7",
    ),
}

OPENSSL_FIPS_PROVIDER_RELEASES = {
    "3.1.2": struct(
        certificate_reference = "CMVP #4985",
        sha256 = "a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539",
        strip_prefix = "openssl-3.1.2",
        urls = ["https://github.com/openssl/openssl/releases/download/openssl-3.1.2/openssl-3.1.2.tar.gz"],
        version = "3.1.2",
    ),
}
