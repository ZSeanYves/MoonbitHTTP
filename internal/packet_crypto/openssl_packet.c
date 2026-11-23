/* OpenSSL 3 EVP packet protection. All inputs are borrowed for this call. */
#include <moonbit.h>
#include <stdint.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

extern void *moon_http_tls_symbol(const char *);
typedef struct evp_pkey_ctx_st PkeyCtx;
typedef struct evp_md_st Digest;
typedef struct evp_cipher_ctx_st CipherCtx;
typedef struct evp_cipher_st Cipher;
typedef struct ossl_lib_ctx_st LibCtx;
typedef struct engine_st Engine;

#define EVP_SYMBOLS(F) \
  F(PkeyCtx *, EVP_PKEY_CTX_new_from_name, (LibCtx *, const char *, const char *)) \
  F(void, EVP_PKEY_CTX_free, (PkeyCtx *)) \
  F(int, EVP_PKEY_derive_init, (PkeyCtx *)) \
  F(int, EVP_PKEY_CTX_set_hkdf_mode, (PkeyCtx *, int)) \
  F(int, EVP_PKEY_CTX_set_hkdf_md, (PkeyCtx *, const Digest *)) \
  F(int, EVP_PKEY_CTX_set1_hkdf_key, (PkeyCtx *, const unsigned char *, int)) \
  F(int, EVP_PKEY_CTX_set1_hkdf_salt, (PkeyCtx *, const unsigned char *, int)) \
  F(int, EVP_PKEY_CTX_add1_hkdf_info, (PkeyCtx *, const unsigned char *, int)) \
  F(int, EVP_PKEY_derive, (PkeyCtx *, unsigned char *, size_t *)) \
  F(const Digest *, EVP_sha256, (void)) \
  F(const Digest *, EVP_sha384, (void)) \
  F(CipherCtx *, EVP_CIPHER_CTX_new, (void)) \
  F(void, EVP_CIPHER_CTX_free, (CipherCtx *)) \
  F(const Cipher *, EVP_aes_128_gcm, (void)) \
  F(const Cipher *, EVP_aes_256_gcm, (void)) \
  F(const Cipher *, EVP_aes_128_ecb, (void)) \
  F(const Cipher *, EVP_aes_256_ecb, (void)) \
  F(int, EVP_CipherInit_ex, (CipherCtx *, const Cipher *, Engine *, const unsigned char *, const unsigned char *, int)) \
  F(int, EVP_CipherUpdate, (CipherCtx *, unsigned char *, int *, const unsigned char *, int)) \
  F(int, EVP_CipherFinal_ex, (CipherCtx *, unsigned char *, int *)) \
  F(int, EVP_CIPHER_CTX_set_padding, (CipherCtx *, int)) \
  F(int, EVP_CIPHER_CTX_ctrl, (CipherCtx *, int, int, void *)) \
  F(void, OPENSSL_cleanse, (void *, size_t))

#define DECLARE(ret, name, args) static ret (*p_##name) args;
EVP_SYMBOLS(DECLARE)
static int ready;
static void bind_evp(void) {
#define BIND(ret, name, args) p_##name = (ret (*) args)moon_http_tls_symbol(#name); if (!p_##name) return;
  EVP_SYMBOLS(BIND)
  ready = 1;
}
#ifdef _WIN32
static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK bind_once(PINIT_ONCE o, PVOID p, PVOID *c) {
  (void)o; (void)p; (void)c; bind_evp(); return TRUE;
}
static int available(void) { InitOnceExecuteOnce(&once, bind_once, NULL, NULL); return ready; }
#else
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int available(void) { pthread_once(&once, bind_evp); return ready; }
#endif

MOONBIT_FFI_EXPORT int moon_http_packet_kdf(int expand, int sha384, uint8_t *key,
                                            uint8_t *param, uint8_t *out) {
  if (!available()) return 0;
  PkeyCtx *ctx = p_EVP_PKEY_CTX_new_from_name(NULL, "HKDF", NULL);
  if (!ctx) return 0;
  size_t size = Moonbit_array_length(out);
  int n = Moonbit_array_length(param);
  int ok = p_EVP_PKEY_derive_init(ctx) > 0 &&
    p_EVP_PKEY_CTX_set_hkdf_mode(ctx, expand ? 2 : 1) > 0 &&
    p_EVP_PKEY_CTX_set_hkdf_md(ctx, sha384 ? p_EVP_sha384() : p_EVP_sha256()) > 0 &&
    p_EVP_PKEY_CTX_set1_hkdf_key(ctx, key, Moonbit_array_length(key)) > 0 &&
    (expand ? p_EVP_PKEY_CTX_add1_hkdf_info(ctx, param, n)
            : p_EVP_PKEY_CTX_set1_hkdf_salt(ctx, param, n)) > 0 &&
    p_EVP_PKEY_derive(ctx, out, &size) > 0 && size == Moonbit_array_length(out);
  p_EVP_PKEY_CTX_free(ctx);
  return ok;
}

enum { GCM_DECRYPT = 0, GCM_ENCRYPT = 1, HEADER_BLOCK = 2,
       GET_TAG = 0x10, SET_TAG = 0x11, TAG_SIZE = 16 };
MOONBIT_FFI_EXPORT int moon_http_packet_cipher(int mode, uint8_t *key, uint8_t *iv,
                                               uint8_t *aad, uint8_t *input, uint8_t *out) {
  int keysz = Moonbit_array_length(key), payload = Moonbit_array_length(input);
  int capacity = Moonbit_array_length(out), aadlen = Moonbit_array_length(aad);
  if (!available() || (keysz != 16 && keysz != 32)) return 0;
  const Cipher *cipher;
  if (mode == HEADER_BLOCK) {
    if (payload != 16 || capacity != 16 || aadlen) return 0;
    cipher = keysz == 16 ? p_EVP_aes_128_ecb() : p_EVP_aes_256_ecb();
  } else {
    if (Moonbit_array_length(iv) != 12) return 0;
    if (mode == GCM_DECRYPT && payload >= TAG_SIZE) payload -= TAG_SIZE;
    else if (mode != GCM_ENCRYPT) return 0;
    if (mode == GCM_ENCRYPT ? capacity < TAG_SIZE || capacity - TAG_SIZE != payload
                            : capacity != payload) return 0;
    cipher = keysz == 16 ? p_EVP_aes_128_gcm() : p_EVP_aes_256_gcm();
  }
  CipherCtx *ctx = p_EVP_CIPHER_CTX_new();
  if (!ctx) return 0;
  int len = 0;
  unsigned char final_block[32];
  int ok = p_EVP_CipherInit_ex(ctx, cipher, NULL, key, mode == HEADER_BLOCK ? NULL : iv,
                               mode != GCM_DECRYPT) == 1 &&
    (mode != HEADER_BLOCK || p_EVP_CIPHER_CTX_set_padding(ctx, 0) == 1) &&
    (!aadlen || p_EVP_CipherUpdate(ctx, NULL, &len, aad, aadlen) == 1) &&
    (!payload || (p_EVP_CipherUpdate(ctx, out, &len, input, payload) == 1 && len == payload)) &&
    (mode != GCM_DECRYPT || p_EVP_CIPHER_CTX_ctrl(ctx, SET_TAG, TAG_SIZE, input + payload) == 1) &&
    p_EVP_CipherFinal_ex(ctx, final_block, &len) == 1 && len == 0 &&
    (mode != GCM_ENCRYPT || p_EVP_CIPHER_CTX_ctrl(ctx, GET_TAG, TAG_SIZE, out + payload) == 1);
  if (!ok && capacity) p_OPENSSL_cleanse(out, capacity);
  p_EVP_CIPHER_CTX_free(ctx);
  return ok;
}
