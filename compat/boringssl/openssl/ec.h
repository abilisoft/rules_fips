/*
 * Consumer compatibility overlay for Erlang/OTP explicit prime curves.
 *
 * BoringSSL accepts prime fields up to EC_MAX_BYTES (66 bytes) but keeps that
 * constant private. It also omits OpenSSL's optional curve-seed metadata API;
 * the seed is not used in elliptic-curve calculations.
 */
#ifndef OTP_BORINGSSL_COMPAT_EC_H
#define OTP_BORINGSSL_COMPAT_EC_H

#include_next <openssl/ec.h>

#define OPENSSL_ECC_MAX_FIELD_BITS 528

static inline size_t EC_GROUP_set_seed(EC_GROUP *group,
                                       const unsigned char *seed,
                                       size_t seed_len) {
    (void)group;
    (void)seed;
    return seed_len;
}

#endif
