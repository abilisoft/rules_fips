/*
 * Consumer compatibility overlay for Erlang/OTP.
 *
 * OTP 29 includes <openssl/modes.h> for OpenSSL >= 1.0 but does not use any
 * declaration from it. BoringSSL identifies as OpenSSL 1.1.1-compatible while
 * intentionally omitting that unused public header. Keep this empty overlay
 * outside both upstream source trees and outside BoringCrypto's bcm.o boundary.
 */
#ifndef OTP_BORINGSSL_COMPAT_MODES_H
#define OTP_BORINGSSL_COMPAT_MODES_H
#endif
