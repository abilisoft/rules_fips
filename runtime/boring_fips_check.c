#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <openssl/crypto.h>
#include <openssl/md5.h>
#include <openssl/service_indicator.h>
#include <openssl/sha.h>

static int fail(const char *message) {
  fprintf(stderr, "BoringCrypto FIPS check failed: %s\n", message);
  return 78;
}

int main(void) {
  static const uint8_t expected_sha256[SHA256_DIGEST_LENGTH] = {
      0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
      0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
      0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
      0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
  };
  uint8_t digest[SHA256_DIGEST_LENGTH];
  uint8_t md5_digest[MD5_DIGEST_LENGTH];
  uint64_t before;
  uint64_t after;

  if (strcmp(FIPS_module_name(), "BoringCrypto") != 0) {
    return fail("unexpected module name");
  }
  if (FIPS_version() != 2023042800u) {
    return fail("unexpected module version");
  }
  if (!FIPS_mode()) {
    return fail("module was not built in FIPS mode");
  }
  if (FIPS_mode_set(0)) {
    return fail("FIPS mode could be disabled");
  }
  if (!BORINGSSL_integrity_test()) {
    return fail("module integrity test failed");
  }

  before = FIPS_service_indicator_before_call();
  if (SHA256((const uint8_t *)"abc", 3, digest) == NULL) {
    return fail("SHA-256 call failed");
  }
  after = FIPS_service_indicator_after_call();
  if (before == after) {
    return fail("SHA-256 was not reported as an approved service");
  }
  if (memcmp(digest, expected_sha256, sizeof(digest)) != 0) {
    return fail("SHA-256 KAT failed");
  }

  before = FIPS_service_indicator_before_call();
  if (MD5((const uint8_t *)"abc", 3, md5_digest) == NULL) {
    return fail("MD5 negative-test call failed");
  }
  after = FIPS_service_indicator_after_call();
  if (before != after) {
    return fail("MD5 was incorrectly reported as an approved service");
  }

  printf("BORINGCRYPTO_FIPS_VERIFIED name=%s version=%u mode=%d\n",
         FIPS_module_name(), FIPS_version(), FIPS_mode());
  return 0;
}
