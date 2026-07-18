/* OTP parses this OpenSSL option unconditionally; BoringSSL rejects it. */
#ifndef OTP_BORINGSSL_COMPAT_RSA_H
#define OTP_BORINGSSL_COMPAT_RSA_H

#include_next <openssl/rsa.h>

#define RSA_X931_PADDING 5

#endif
