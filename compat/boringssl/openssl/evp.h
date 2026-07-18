/*
 * Consumer feature overlay for Erlang/OTP.
 *
 * OTP 29 assumes that every OpenSSL-compatible 1.0.1+ library implements the
 * EVP AES-CCM accessors. BoringSSL does not. Returning NULL is the mechanism
 * OTP already uses for unavailable ciphers, so these declarations keep CCM
 * out of crypto:supports/0 without emulating or substituting an algorithm.
 */
#ifndef OTP_BORINGSSL_COMPAT_EVP_H
#define OTP_BORINGSSL_COMPAT_EVP_H

#include_next <openssl/evp.h>

static inline const EVP_CIPHER *EVP_aes_128_cfb8(void) { return NULL; }
static inline const EVP_CIPHER *EVP_aes_192_cfb8(void) { return NULL; }
static inline const EVP_CIPHER *EVP_aes_256_cfb8(void) { return NULL; }
static inline const EVP_CIPHER *otp_boringssl_aes_cfb128_unavailable(void)
{
    return NULL;
}
static inline const EVP_CIPHER *EVP_aes_128_ccm(void) { return NULL; }
static inline const EVP_CIPHER *EVP_aes_192_ccm(void) { return NULL; }
static inline const EVP_CIPHER *EVP_aes_256_ccm(void) { return NULL; }

#define EVP_aes_128_cfb128 otp_boringssl_aes_cfb128_unavailable
#define EVP_aes_192_cfb128 otp_boringssl_aes_cfb128_unavailable
#define EVP_aes_256_cfb128 otp_boringssl_aes_cfb128_unavailable
#define EVP_CIPHER_type EVP_CIPHER_nid
#define EVP_CTRL_CCM_SET_IVLEN 0
#define EVP_CTRL_CCM_GET_TAG 0
#define EVP_CTRL_CCM_SET_TAG 0
#define EVP_PKEY_CMAC EVP_PKEY_NONE
#define EVP_PKEY_HMAC EVP_PKEY_NONE

#endif
