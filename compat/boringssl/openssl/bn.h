#ifndef OTP_BORINGSSL_COMPAT_OPENSSL_BN_H
#define OTP_BORINGSSL_COMPAT_OPENSSL_BN_H

#include_next <openssl/bn.h>

/*
 * OTP's SRP implementation marks secret exponents with OpenSSL's historical
 * BN_FLG_CONSTTIME flag. BoringSSL intentionally removed that flag in favour
 * of explicit constant-time entry points.
 *
 * SRP is unavailable in this build: each OTP SRP NIF rejects the call before
 * reaching any BN operation when FIPS_mode() is true, and a BoringCrypto FIPS
 * build hard-wires FIPS_mode() to true. These definitions exist only so that
 * the unreachable, non-FIPS SRP implementation can be compiled. The runtime
 * verifier checks that FIPS mode cannot be disabled; OTP's FIPS guards are
 * responsible for rejecting the unreachable SRP NIF entry points.
 */
#define BN_FLG_CONSTTIME 0
#define BN_set_flags(bn, flags) \
    ((void)(bn), (void)(flags))

#endif
