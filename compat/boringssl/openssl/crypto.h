/*
 * Consumer compatibility overlay for Erlang/OTP.
 *
 * BoringSSL owns and destroys its thread-local crypto state when each thread
 * exits. OTP calls OpenSSL's OPENSSL_thread_stop() from its NIF unload hook,
 * but BoringSSL intentionally does not expose that OpenSSL lifecycle API.
 * The static crypto NIF and BoringCrypto code remain resident with the VM, so
 * no code is unloaded while BoringSSL still owns thread-local destructors.
 */
#ifndef OTP_BORINGSSL_COMPAT_CRYPTO_H
#define OTP_BORINGSSL_COMPAT_CRYPTO_H

#include_next <openssl/crypto.h>

static inline void OPENSSL_thread_stop(void) {}

#endif
