/* Select OTP's existing low-level CMAC path for BoringSSL. */
#ifndef OTP_BORINGSSL_COMPAT_CMAC_H
#define OTP_BORINGSSL_COMPAT_CMAC_H

#include_next <openssl/cmac.h>

#undef HAVE_EVP_PKEY_new_CMAC_key

#endif
