/*
 * Consumer feature overlay for Erlang/OTP.
 *
 * OTP infers several legacy EVP ciphers from OpenSSL's version number. Those
 * entry points are not part of BoringSSL's supported libcrypto surface (some
 * live only in libdecrepit), and none are needed by the FIPS runtime.
 */
#ifndef OTP_BORINGSSL_COMPAT_OPENSSLCONF_H
#define OTP_BORINGSSL_COMPAT_OPENSSLCONF_H

#include_next <openssl/opensslconf.h>

#define OPENSSL_NO_BF
#define OPENSSL_NO_CHACHA
#define OPENSSL_NO_DES
#define OPENSSL_NO_POLY1305
#define OPENSSL_NO_RC2
#define OPENSSL_NO_RC4

#endif
