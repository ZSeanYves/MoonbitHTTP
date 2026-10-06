/* Thin OpenSSL 3 memory-BIO adapter. TLS, X.509 and key parsing remain in
 * OpenSSL. Stable public ABI declarations avoid a platform-specific SDK path.
 * No MoonBit pointer is retained after an FFI call; the external object owns
 * SSL, SSL_CTX and the copied ALPN list. */
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_method_st SSL_METHOD;
typedef struct ssl_cipher_st SSL_CIPHER;
typedef struct bio_st BIO;
typedef struct bio_method_st BIO_METHOD;
typedef struct x509_st X509;
typedef struct x509_store_st X509_STORE;
typedef struct X509_VERIFY_PARAM_st X509_VERIFY_PARAM;
typedef struct evp_pkey_st EVP_PKEY;
typedef struct evp_md_st EVP_MD;
typedef struct stack_st_X509 STACK_OF_X509;
typedef struct x509_crl_st X509_CRL;
typedef struct ocsp_response_st OCSP_RESPONSE;
typedef struct ocsp_basic_response_st OCSP_BASICRESP;
typedef struct ocsp_cert_id_st OCSP_CERTID;
typedef struct asn1_generalized_time_st ASN1_GENERALIZEDTIME;

typedef struct {
  SSL_CTX *ctx;
  SSL *ssl;
  BIO *input;
  BIO *output;
  unsigned char *alpn;
  unsigned int alpn_len;
  uint64_t error_code;
  int64_t verify_code;
  char error[384];
  int initialized;
  int require_ocsp;
  int has_ocsp_staple;
} HttpTls;

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#else
#include <dlfcn.h>
#include <pthread.h>
#endif

#define TLS_SYMBOLS(F) \
  F(unsigned long, OpenSSL_version_num, (void)) \
  F(void *, CRYPTO_malloc, (size_t, const char *, int)) \
  F(void, CRYPTO_free, (void *, const char *, int)) \
  F(const SSL_METHOD *, TLS_method, (void)) \
  F(SSL_CTX *, SSL_CTX_new, (const SSL_METHOD *)) \
  F(void, SSL_CTX_free, (SSL_CTX *)) \
  F(long, SSL_CTX_ctrl, (SSL_CTX *, int, long, void *)) \
  F(uint64_t, SSL_CTX_set_options, (SSL_CTX *, uint64_t)) \
  F(void, SSL_CTX_set_verify, (SSL_CTX *, int, void *)) \
  F(int, SSL_CTX_set_default_verify_paths, (SSL_CTX *)) \
  F(X509_STORE *, SSL_CTX_get_cert_store, (const SSL_CTX *)) \
  F(int, X509_STORE_add_cert, (X509_STORE *, X509 *)) \
  F(int, X509_STORE_add_crl, (X509_STORE *, X509_CRL *)) \
  F(int, X509_STORE_set_flags, (X509_STORE *, unsigned long)) \
  F(int, SSL_CTX_use_certificate, (SSL_CTX *, X509 *)) \
  F(int, SSL_CTX_use_PrivateKey, (SSL_CTX *, EVP_PKEY *)) \
  F(int, SSL_CTX_check_private_key, (const SSL_CTX *)) \
  F(void, SSL_CTX_set_alpn_select_cb, (SSL_CTX *, int (*)(SSL *, const unsigned char **, unsigned char *, const unsigned char *, unsigned int, void *), void *)) \
  F(long, SSL_CTX_callback_ctrl, (SSL_CTX *, int, void (*)(void))) \
  F(SSL *, SSL_new, (SSL_CTX *)) \
  F(void, SSL_free, (SSL *)) \
  F(void, SSL_set0_rbio, (SSL *, BIO *)) \
  F(void, SSL_set0_wbio, (SSL *, BIO *)) \
  F(void, SSL_set_connect_state, (SSL *)) \
  F(void, SSL_set_accept_state, (SSL *)) \
  F(int, SSL_do_handshake, (SSL *)) \
  F(int, SSL_get_error, (const SSL *, int)) \
  F(long, SSL_ctrl, (SSL *, int, long, void *)) \
  F(int, SSL_set1_host, (SSL *, const char *)) \
  F(void, SSL_set_hostflags, (SSL *, unsigned int)) \
  F(X509_VERIFY_PARAM *, SSL_get0_param, (SSL *)) \
  F(int, X509_VERIFY_PARAM_set1_ip_asc, (X509_VERIFY_PARAM *, const char *)) \
  F(int, SSL_set_alpn_protos, (SSL *, const unsigned char *, unsigned int)) \
  F(void, SSL_get0_alpn_selected, (const SSL *, const unsigned char **, unsigned int *)) \
  F(int, SSL_read, (SSL *, void *, int)) \
  F(int, SSL_write, (SSL *, const void *, int)) \
  F(int, SSL_shutdown, (SSL *)) \
  F(int, SSL_version, (const SSL *)) \
  F(const SSL_CIPHER *, SSL_get_current_cipher, (const SSL *)) \
  F(const char *, SSL_CIPHER_standard_name, (const SSL_CIPHER *)) \
  F(long, SSL_get_verify_result, (const SSL *)) \
  F(X509 *, SSL_get1_peer_certificate, (const SSL *)) \
  F(const STACK_OF_X509 *, SSL_get0_verified_chain, (const SSL *)) \
  F(const BIO_METHOD *, BIO_s_mem, (void)) \
  F(BIO *, BIO_new, (const BIO_METHOD *)) \
  F(BIO *, BIO_new_mem_buf, (const void *, int)) \
  F(int, BIO_free, (BIO *)) \
  F(int, BIO_write, (BIO *, const void *, int)) \
  F(int, BIO_read, (BIO *, void *, int)) \
  F(size_t, BIO_ctrl_pending, (BIO *)) \
  F(long, BIO_ctrl, (BIO *, int, long, void *)) \
  F(X509 *, PEM_read_bio_X509, (BIO *, X509 **, int (*)(char *, int, int, void *), void *)) \
  F(X509_CRL *, PEM_read_bio_X509_CRL, (BIO *, X509_CRL **, int (*)(char *, int, int, void *), void *)) \
  F(EVP_PKEY *, PEM_read_bio_PrivateKey, (BIO *, EVP_PKEY **, int (*)(char *, int, int, void *), void *)) \
  F(void, X509_free, (X509 *)) \
  F(void, X509_CRL_free, (X509_CRL *)) \
  F(void, EVP_PKEY_free, (EVP_PKEY *)) \
  F(const EVP_MD *, EVP_sha1, (void)) \
  F(OCSP_RESPONSE *, d2i_OCSP_RESPONSE, (OCSP_RESPONSE **, const unsigned char **, long)) \
  F(void, OCSP_RESPONSE_free, (OCSP_RESPONSE *)) \
  F(int, OCSP_response_status, (OCSP_RESPONSE *)) \
  F(OCSP_BASICRESP *, OCSP_response_get1_basic, (OCSP_RESPONSE *)) \
  F(void, OCSP_BASICRESP_free, (OCSP_BASICRESP *)) \
  F(int, OCSP_basic_verify, (OCSP_BASICRESP *, STACK_OF_X509 *, X509_STORE *, unsigned long)) \
  F(OCSP_CERTID *, OCSP_cert_to_id, (const EVP_MD *, const X509 *, const X509 *)) \
  F(void, OCSP_CERTID_free, (OCSP_CERTID *)) \
  F(int, OCSP_resp_find_status, (OCSP_BASICRESP *, OCSP_CERTID *, int *, int *, ASN1_GENERALIZEDTIME **, ASN1_GENERALIZEDTIME **, ASN1_GENERALIZEDTIME **)) \
  F(int, OCSP_check_validity, (ASN1_GENERALIZEDTIME *, ASN1_GENERALIZEDTIME *, long, long)) \
  F(int, OPENSSL_sk_num, (const void *)) \
  F(void *, OPENSSL_sk_value, (const void *, int)) \
  F(unsigned long, ERR_get_error, (void)) \
  F(void, ERR_clear_error, (void)) \
  F(void, ERR_error_string_n, (unsigned long, char *, size_t)) \
  F(const char *, X509_verify_cert_error_string, (long))

#define DECLARE_SYMBOL(ret, name, args) static ret (*p_##name) args;
TLS_SYMBOLS(DECLARE_SYMBOL)
#undef DECLARE_SYMBOL
#ifdef _WIN32
static INIT_ONCE tls_once = INIT_ONCE_STATIC_INIT;
typedef HMODULE TlsModule;
#else
static pthread_once_t tls_once = PTHREAD_ONCE_INIT;
typedef void *TlsModule;
#endif
static TlsModule tls_library = NULL;
static TlsModule crypto_library = NULL;
static int tls_available = 0;

static void close_modules(TlsModule ssl, TlsModule crypto) {
#ifdef _WIN32
  if (ssl) FreeLibrary(ssl);
  if (crypto) FreeLibrary(crypto);
#else
  if (ssl) dlclose(ssl);
  if (crypto) dlclose(crypto);
#endif
}

static void *find_symbol(TlsModule ssl, TlsModule crypto, const char *name) {
#ifdef _WIN32
  void *symbol = (void *)GetProcAddress(ssl, name);
  return symbol ? symbol : (void *)GetProcAddress(crypto, name);
#else
  void *symbol = dlsym(ssl, name);
  return symbol ? symbol : dlsym(crypto, name);
#endif
}

#ifdef _WIN32
static int load_module_pair(const wchar_t *ssl_path, const wchar_t *crypto_path,
                            DWORD flags, TlsModule *ssl, TlsModule *crypto) {
  /* Windows does not search dependency DLL exports in GetProcAddress. Both
   * modules must be loaded, from the same explicitly selected installation. */
  *crypto = LoadLibraryExW(crypto_path, NULL, flags);
  *ssl = *crypto ? LoadLibraryExW(ssl_path, NULL, flags) : NULL;
  if (*ssl) return 1;
  close_modules(*ssl, *crypto); *ssl = NULL; *crypto = NULL;
  return 0;
}

static int load_modules(TlsModule *ssl, TlsModule *crypto) {
  const wchar_t *ssl_names[] = { L"libssl-3-x64.dll", L"libssl-3-arm64.dll", L"libssl-3.dll", NULL };
  const wchar_t *crypto_names[] = { L"libcrypto-3-x64.dll", L"libcrypto-3-arm64.dll", L"libcrypto-3.dll", NULL };
  DWORD length = GetEnvironmentVariableW(L"OPENSSL_ROOT_DIR", NULL, 0);
  if (length) {
    wchar_t *root = malloc(((size_t)length + 1) * sizeof(wchar_t));
    wchar_t *ssl_path = malloc(((size_t)length + 64) * sizeof(wchar_t));
    wchar_t *crypto_path = malloc(((size_t)length + 64) * sizeof(wchar_t));
    if (!root || !ssl_path || !crypto_path) { free(root); free(ssl_path); free(crypto_path); return 0; }
    DWORD actual = GetEnvironmentVariableW(L"OPENSSL_ROOT_DIR", root, length + 1);
    int absolute = actual >= 3 && ((root[1] == L':' && (root[2] == L'\\' || root[2] == L'/')) || (root[0] == L'\\' && root[1] == L'\\'));
    int loaded = 0;
    if (actual && actual <= length && absolute) {
      for (int i = 0; ssl_names[i] && !loaded; ++i) {
        swprintf(ssl_path, (size_t)length + 64, L"%ls\\bin\\%ls", root, ssl_names[i]);
        swprintf(crypto_path, (size_t)length + 64, L"%ls\\bin\\%ls", root, crypto_names[i]);
        loaded = load_module_pair(ssl_path, crypto_path,
          LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32, ssl, crypto);
      }
    }
    free(root); free(ssl_path); free(crypto_path);
    return loaded; /* Explicit selection never silently falls back. */
  }
  for (int i = 0; ssl_names[i]; ++i) {
    if (load_module_pair(ssl_names[i], crypto_names[i], LOAD_LIBRARY_SEARCH_DEFAULT_DIRS, ssl, crypto)) return 1;
  }
  return 0;
}
#else
static int load_module_pair(const char *ssl_path, const char *crypto_path,
                            TlsModule *ssl, TlsModule *crypto) {
  *crypto = dlopen(crypto_path, RTLD_NOW | RTLD_LOCAL);
  *ssl = *crypto ? dlopen(ssl_path, RTLD_NOW | RTLD_LOCAL) : NULL;
  if (*ssl) return 1;
  close_modules(*ssl, *crypto); *ssl = NULL; *crypto = NULL;
  return 0;
}

static int load_modules(TlsModule *ssl, TlsModule *crypto) {
  const char *root = getenv("OPENSSL_ROOT_DIR");
#ifdef __APPLE__
  const char *ssl_name = "libssl.3.dylib", *crypto_name = "libcrypto.3.dylib";
#else
  const char *ssl_name = "libssl.so.3", *crypto_name = "libcrypto.so.3";
#endif
  if (root && root[0]) {
    if (root[0] != '/') return 0;
    size_t capacity = strlen(root) + 64;
    char *ssl_path = malloc(capacity), *crypto_path = malloc(capacity);
    if (!ssl_path || !crypto_path) { free(ssl_path); free(crypto_path); return 0; }
    const char *directories[] = { "lib", "lib64", NULL };
    int loaded = 0;
    for (int i = 0; directories[i] && !loaded; ++i) {
      snprintf(ssl_path, capacity, "%s/%s/%s", root, directories[i], ssl_name);
      snprintf(crypto_path, capacity, "%s/%s/%s", root, directories[i], crypto_name);
      loaded = load_module_pair(ssl_path, crypto_path, ssl, crypto);
    }
    free(ssl_path); free(crypto_path);
    return loaded;
  }
#ifdef __APPLE__
  if (load_module_pair("/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib", "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib", ssl, crypto)) return 1;
  if (load_module_pair("/usr/local/opt/openssl@3/lib/libssl.3.dylib", "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib", ssl, crypto)) return 1;
#endif
  return load_module_pair(ssl_name, crypto_name, ssl, crypto);
}
#endif

static void load_tls(void) {
  TlsModule library = NULL, crypto = NULL;
  if (!load_modules(&library, &crypto)) return;
#define LOAD_SYMBOL(ret, name, args) p_##name = (ret (*) args)find_symbol(library, crypto, #name); if (!p_##name) { close_modules(library, crypto); return; }
  TLS_SYMBOLS(LOAD_SYMBOL)
#undef LOAD_SYMBOL
  if (p_OpenSSL_version_num() < 0x30000000UL) { close_modules(library, crypto); return; }
  tls_library = library;
  crypto_library = crypto;
  tls_available = 1;
  /* Keep the library loaded for the lifetime of handles and finalizers. */
}

#ifdef _WIN32
static BOOL CALLBACK load_tls_once(PINIT_ONCE once, PVOID parameter, PVOID *context) {
  (void)once; (void)parameter; (void)context;
  load_tls();
  return TRUE;
}
static void ensure_tls_loaded(void) { InitOnceExecuteOnce(&tls_once, load_tls_once, NULL, NULL); }
#else
static void ensure_tls_loaded(void) { pthread_once(&tls_once, load_tls); }
#endif

MOONBIT_FFI_EXPORT void *moon_http_tls_symbol(const char *name) {
  ensure_tls_loaded();
  if (!tls_library) return NULL;
  return find_symbol(tls_library, crypto_library, name);
}

static void capture_error(HttpTls *self, const char *fallback) {
  self->error_code = p_ERR_get_error();
  self->verify_code = self->ssl ? p_SSL_get_verify_result(self->ssl) : 0;
  if (self->verify_code != 0) {
    snprintf(self->error, sizeof(self->error), "%s", p_X509_verify_cert_error_string((long)self->verify_code));
  } else if (self->error_code) {
    p_ERR_error_string_n((unsigned long)self->error_code, self->error, sizeof(self->error));
  } else {
    snprintf(self->error, sizeof(self->error), "%s", fallback);
  }
}

static void release_tls(void *object) {
  HttpTls *self = object;
  if (self->ssl) p_SSL_free(self->ssl);
  if (self->ctx) p_SSL_CTX_free(self->ctx);
  free(self->alpn);
  self->ssl = NULL; self->ctx = NULL;
  self->input = NULL; self->output = NULL; self->alpn = NULL;
  self->initialized = 0;
}

static int no_password(char *buf, int size, int rw, void *data) {
  (void)buf; (void)size; (void)rw; (void)data;
  return 0;
}

static int bio_trailing_whitespace(BIO *bio) {
  unsigned char buffer[256];
  while (p_BIO_ctrl_pending(bio) > 0) {
    size_t pending = p_BIO_ctrl_pending(bio);
    int requested = pending > sizeof(buffer) ? (int)sizeof(buffer) : (int)pending;
    int read = p_BIO_read(bio, buffer, requested);
    if (read <= 0) return 0;
    for (int i = 0; i < read; ++i) {
      unsigned char byte = buffer[i];
      if (byte != ' ' && byte != '\t' && byte != '\r' &&
          byte != '\n' && byte != '\f' && byte != '\v') {
        return 0;
      }
    }
  }
  return 1;
}

static int pem_byte_is_whitespace(unsigned char byte) {
  return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' ||
    byte == '\f' || byte == '\v';
}

static int pem_block_count(const unsigned char *pem, int length,
                           const char *begin_marker, const char *end_marker) {
  size_t begin_length = strlen(begin_marker);
  size_t end_length = strlen(end_marker);
  size_t position = 0;
  int count = 0;
  while (position < (size_t)length) {
    while (position < (size_t)length && pem_byte_is_whitespace(pem[position])) {
      ++position;
    }
    if (position == (size_t)length) break;
    if (position + begin_length > (size_t)length ||
        memcmp(pem + position, begin_marker, begin_length)) {
      return -1;
    }
    position += begin_length;
    size_t end = position;
    while (end + end_length <= (size_t)length &&
           memcmp(pem + end, end_marker, end_length)) {
      ++end;
    }
    if (end + end_length > (size_t)length) return -1;
    position = end + end_length;
    ++count;
  }
  return count;
}

static int pem_certificate_chain_count(const unsigned char *pem, int length) {
  const char *begin_marker = "-----BEGIN CERTIFICATE-----";
  const char *end_marker = "-----END CERTIFICATE-----";
  size_t begin_length = strlen(begin_marker);
  size_t end_length = strlen(end_marker);
  size_t position = 0;
  while (position + begin_length <= (size_t)length &&
         memcmp(pem + position, begin_marker, begin_length)) {
    ++position;
  }
  if (position + begin_length > (size_t)length) return -1;
  int count = 0;
  for (;;) {
    size_t end = position + begin_length;
    while (end + end_length <= (size_t)length &&
           memcmp(pem + end, end_marker, end_length)) {
      ++end;
    }
    if (end + end_length > (size_t)length) return -1;
    position = end + end_length;
    ++count;
    while (position < (size_t)length && pem_byte_is_whitespace(pem[position])) {
      ++position;
    }
    if (position == (size_t)length) return count;
    if (position + begin_length > (size_t)length ||
        memcmp(pem + position, begin_marker, begin_length)) return -1;
  }
}

static int load_roots(HttpTls *self, const unsigned char *pem, int length) {
  BIO *bio = p_BIO_new_mem_buf(pem, length);
  if (!bio) return 0;
  int count = 0;
  X509 *cert;
  while ((cert = p_PEM_read_bio_X509(bio, NULL, NULL, NULL))) {
    int ok = p_X509_STORE_add_cert(p_SSL_CTX_get_cert_store(self->ctx), cert);
    p_X509_free(cert);
    if (ok != 1) { p_BIO_free(bio); return 0; }
    ++count;
  }
  int expected_blocks = pem_block_count(
    pem, length, "-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----");
  int only_whitespace = bio_trailing_whitespace(bio) &&
    expected_blocks > 0 && expected_blocks == count;
  p_BIO_free(bio);
  if (!count || !only_whitespace) return 0;
  p_ERR_clear_error(); /* PEM reports end-of-input through the error queue. */
  return 1;
}

static int load_crls(HttpTls *self, const unsigned char *pem, int length) {
  BIO *bio = p_BIO_new_mem_buf(pem, length);
  if (!bio) return 0;
  int count = 0;
  X509_CRL *crl;
  while ((crl = p_PEM_read_bio_X509_CRL(bio, NULL, NULL, NULL))) {
    int ok = p_X509_STORE_add_crl(p_SSL_CTX_get_cert_store(self->ctx), crl);
    p_X509_CRL_free(crl);
    if (ok != 1) { p_BIO_free(bio); return 0; }
    ++count;
  }
  int expected_blocks = pem_block_count(
    pem, length, "-----BEGIN X509 CRL-----", "-----END X509 CRL-----");
  int only_whitespace = bio_trailing_whitespace(bio) &&
    expected_blocks > 0 && expected_blocks == count;
  p_BIO_free(bio);
  if (!count || !only_whitespace) return 0;
  p_ERR_clear_error();
  /* Check every certificate in the verified chain, not only the leaf. */
  if (p_X509_STORE_set_flags(p_SSL_CTX_get_cert_store(self->ctx), 0xCUL) != 1) return 0;
  return 1;
}

static int install_ocsp_staple(HttpTls *self, const unsigned char *response, int length) {
  if (!length) return 1;
  unsigned char *copy = p_CRYPTO_malloc((size_t)length, __FILE__, __LINE__);
  if (!copy) return 0;
  memcpy(copy, response, (size_t)length);
  /* SSL owns a successful transfer and releases it with OPENSSL_free, which
   * calls CRYPTO_free. Its allocator may differ from the application's CRT. */
  if (p_SSL_ctrl(self->ssl, 71, length, copy) != 1) {
    p_CRYPTO_free(copy, __FILE__, __LINE__);
    return 0;
  }
  return 1;
}

static void request_ocsp_staple(HttpTls *self) {
  /* TLSEXT_STATUSTYPE_ocsp = 1. A client sends this extension in ClientHello. */
  (void)p_SSL_ctrl(self->ssl, 65, 1, NULL);
}

static int ocsp_status_cb(SSL *ssl, void *arg) {
  HttpTls *self = arg;
  if (!self || self->ssl != ssl || !self->has_ocsp_staple) return 2;
  return 0;
}

static int load_identity(HttpTls *self, const unsigned char *certs, int cert_len, const unsigned char *key, int key_len) {
  BIO *bio = p_BIO_new_mem_buf(certs, cert_len);
  if (!bio) return 0;
  X509 *leaf = p_PEM_read_bio_X509(bio, NULL, NULL, NULL);
  if (!leaf) { p_BIO_free(bio); return 0; }
  int ok = p_SSL_CTX_use_certificate(self->ctx, leaf);
  p_X509_free(leaf);
  if (ok != 1) { p_BIO_free(bio); return 0; }
  int certificate_count = 1;
  X509 *extra;
  while ((extra = p_PEM_read_bio_X509(bio, NULL, NULL, NULL))) {
    if (p_SSL_CTX_ctrl(self->ctx, 14, 0, extra) != 1) {
      p_X509_free(extra); p_BIO_free(bio); return 0;
    }
    /* SSL_CTX now owns the extra chain certificate. */
    ++certificate_count;
  }
  int expected_certificates = pem_certificate_chain_count(certs, cert_len);
  p_BIO_free(bio);
  if (expected_certificates <= 0 ||
      expected_certificates != certificate_count) return 0;
  p_ERR_clear_error();
  bio = p_BIO_new_mem_buf(key, key_len);
  if (!bio) return 0;
  EVP_PKEY *private_key = p_PEM_read_bio_PrivateKey(bio, NULL, no_password, NULL);
  p_BIO_free(bio);
  if (!private_key) return 0;
  ok = p_SSL_CTX_use_PrivateKey(self->ctx, private_key);
  p_EVP_PKEY_free(private_key);
  return ok == 1 && p_SSL_CTX_check_private_key(self->ctx) == 1;
}

static int select_alpn(SSL *ssl, const unsigned char **out, unsigned char *out_len, const unsigned char *in, unsigned int in_len, void *arg) {
  (void)ssl;
  HttpTls *self = arg;
  for (unsigned int i = 0; i < self->alpn_len;) {
    unsigned int n = self->alpn[i++];
    if (!n || n > self->alpn_len - i) return 2;
    for (unsigned int j = 0; j < in_len;) {
      unsigned int m = in[j++];
      if (!m || m > in_len - j) return 2;
      if (n == m && !memcmp(self->alpn + i, in + j, n)) {
        *out = self->alpn + i; *out_len = (unsigned char)n; return 0;
      }
      j += m;
    }
    i += n;
  }
  return 2; /* Fatal no_application_protocol, never silently fall back. */
}

MOONBIT_FFI_EXPORT HttpTls *moon_http_tls_new(int server, int verify, int system_roots, int min_version, int max_version, moonbit_bytes_t host, int numeric_host, moonbit_bytes_t roots, moonbit_bytes_t crls, int require_crl, int require_ocsp, moonbit_bytes_t ocsp_response, moonbit_bytes_t cert, moonbit_bytes_t key, moonbit_bytes_t alpn) {
  HttpTls *self = moonbit_make_external_object(release_tls, sizeof(HttpTls));
  memset(self, 0, sizeof(*self));
  ensure_tls_loaded();
  if (!tls_available) { self->initialized = -1; snprintf(self->error, sizeof(self->error), "OpenSSL 3 shared library is unavailable"); return self; }
  p_ERR_clear_error();
  self->ctx = p_SSL_CTX_new(p_TLS_method());
  if (!self->ctx) goto failed;
  if (p_SSL_CTX_ctrl(self->ctx, 123, min_version, NULL) != 1) goto failed;
  if (max_version && p_SSL_CTX_ctrl(self->ctx, 124, max_version, NULL) != 1) goto failed;
  p_SSL_CTX_set_options(self->ctx, ((uint64_t)1 << 30)); /* NO_RENEGOTIATION */
  p_SSL_CTX_ctrl(self->ctx, 44, 0, NULL); /* Session cache disabled. */
  p_SSL_CTX_set_verify(self->ctx, verify ? (server ? 3 : 1) : 0, NULL);
  int root_len = Moonbit_array_length(roots);
  if (root_len) { if (!load_roots(self, roots, root_len)) goto failed; }
  else if (verify && system_roots) { if (p_SSL_CTX_set_default_verify_paths(self->ctx) != 1) goto failed; }
  else if (verify) { snprintf(self->error, sizeof(self->error), "certificate verification requires trust anchors"); return self; }
  int crl_len = Moonbit_array_length(crls);
  if (crl_len) { if (!load_crls(self, crls, crl_len)) goto failed; }
  else if (require_crl) { snprintf(self->error, sizeof(self->error), "certificate revocation requires CRL material"); return self; }
  self->require_ocsp = require_ocsp;
  int cert_len = Moonbit_array_length(cert), key_len = Moonbit_array_length(key);
  if (cert_len && key_len) { if (!load_identity(self, cert, cert_len, key, key_len)) goto failed; }
  else if (server) { snprintf(self->error, sizeof(self->error), "server certificate and private key are required"); return self; }
  self->alpn_len = (unsigned int)Moonbit_array_length(alpn);
  if (self->alpn_len) {
    self->alpn = malloc(self->alpn_len);
    if (!self->alpn) goto failed;
    memcpy(self->alpn, alpn, self->alpn_len);
  }
  if (server) p_SSL_CTX_set_alpn_select_cb(self->ctx, select_alpn, self);
  self->ssl = p_SSL_new(self->ctx);
  if (!self->ssl) goto failed;
  self->input = p_BIO_new(p_BIO_s_mem());
  self->output = p_BIO_new(p_BIO_s_mem());
  if (!self->input || !self->output) {
    if (self->input) p_BIO_free(self->input);
    if (self->output) p_BIO_free(self->output);
    self->input = NULL; self->output = NULL; goto failed;
  }
  p_SSL_set0_rbio(self->ssl, self->input);
  p_SSL_set0_wbio(self->ssl, self->output);
  if (server) p_SSL_set_accept_state(self->ssl);
  else {
    p_SSL_set_connect_state(self->ssl);
    if (Moonbit_array_length(host)) {
      size_t host_len = (size_t)Moonbit_array_length(host);
      char *host_string = malloc(host_len + 1);
      if (!host_string || memchr(host, 0, host_len)) { free(host_string); goto failed; }
      memcpy(host_string, host, host_len);
      host_string[host_len] = '\0';
      if (numeric_host) {
        if (p_X509_VERIFY_PARAM_set1_ip_asc(p_SSL_get0_param(self->ssl), host_string) != 1) { free(host_string); goto failed; }
      } else {
        /* X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS: a wildcard represents the
         * entire leftmost DNS label, never a prefix or suffix within it. */
        p_SSL_set_hostflags(self->ssl, 0x4U);
        if (p_SSL_set1_host(self->ssl, host_string) != 1) { free(host_string); goto failed; }
        if (p_SSL_ctrl(self->ssl, 55, 0, host_string) != 1) { free(host_string); goto failed; }
      }
      free(host_string);
    }
    if (p_SSL_set_alpn_protos(self->ssl, self->alpn, self->alpn_len) != 0) goto failed;
    /* Ask every verified client for a staple. Optional mode permits absence,
     * but a supplied staple must still pass signature, identity and freshness
     * checks instead of being silently ignored. */
    if (!server) request_ocsp_staple(self);
  }
  if (server && ocsp_response && Moonbit_array_length(ocsp_response)) {
    if (!install_ocsp_staple(self, ocsp_response, Moonbit_array_length(ocsp_response))) goto failed;
    self->has_ocsp_staple = 1;
    if (p_SSL_CTX_ctrl(self->ctx, 64, 0, self) != 1) goto failed;
    if (p_SSL_CTX_callback_ctrl(self->ctx, 63, (void (*)(void))ocsp_status_cb) != 1) goto failed;
  }
  self->initialized = 1;
  return self;
failed:
  capture_error(self, "OpenSSL configuration failed");
  return self;
}

static int ocsp_fail(HttpTls *self, int64_t code, const char *message) {
  self->verify_code = code;
  self->error_code = 0;
  snprintf(self->error, sizeof(self->error), "%s", message);
  return 0;
}

MOONBIT_FFI_EXPORT int moon_http_tls_check_ocsp(HttpTls *self, int require) {
  if (!self || !self->ssl || self->initialized != 1) return 0;
  unsigned char *encoded = NULL;
  long encoded_len = p_SSL_ctrl(self->ssl, 70, 0, &encoded);
  if (encoded_len <= 0 || !encoded) {
    if (require) return ocsp_fail(self, 100, "required OCSP staple was not provided");
    return 1;
  }
  const unsigned char *cursor = encoded;
  OCSP_RESPONSE *response = p_d2i_OCSP_RESPONSE(NULL, &cursor, encoded_len);
  if (!response || cursor != encoded + encoded_len) {
    if (response) p_OCSP_RESPONSE_free(response);
    return ocsp_fail(self, 96, "OCSP response is malformed");
  }
  if (p_OCSP_response_status(response) != 0) {
    p_OCSP_RESPONSE_free(response);
    return ocsp_fail(self, 100, "OCSP responder did not return a successful response");
  }
  OCSP_BASICRESP *basic = p_OCSP_response_get1_basic(response);
  if (!basic) {
    p_OCSP_RESPONSE_free(response);
    return ocsp_fail(self, 96, "OCSP response has no basic response");
  }
  X509 *peer = p_SSL_get1_peer_certificate(self->ssl);
  const STACK_OF_X509 *chain = p_SSL_get0_verified_chain(self->ssl);
  int chain_len = chain ? p_OPENSSL_sk_num(chain) : 0;
  X509 *issuer = chain_len > 1 ? (X509 *)p_OPENSSL_sk_value(chain, 1) : peer;
  if (!peer || !issuer || !chain || p_OCSP_basic_verify(basic, (STACK_OF_X509 *)chain, p_SSL_CTX_get_cert_store(self->ctx), 0) != 1) {
    if (peer) p_X509_free(peer);
    p_OCSP_BASICRESP_free(basic);
    p_OCSP_RESPONSE_free(response);
    return ocsp_fail(self, 97, "OCSP response signature or responder trust check failed");
  }
  OCSP_CERTID *id = p_OCSP_cert_to_id(p_EVP_sha1(), peer, issuer);
  int status = -1;
  int reason = 0;
  ASN1_GENERALIZEDTIME *revoked_at = NULL;
  ASN1_GENERALIZEDTIME *this_update = NULL;
  ASN1_GENERALIZEDTIME *next_update = NULL;
  int found = id && p_OCSP_resp_find_status(basic, id, &status, &reason, &revoked_at, &this_update, &next_update);
  /* Stapled status must have an explicit expiry and a bounded age, even if
   * the responder signs a distant nextUpdate. Allow five minutes of skew. */
  int valid_time = found && this_update && next_update &&
    p_OCSP_check_validity(this_update, next_update, 300L, 7L * 24L * 60L * 60L) == 1;
  if (id) p_OCSP_CERTID_free(id);
  if (peer) p_X509_free(peer);
  p_OCSP_BASICRESP_free(basic);
  p_OCSP_RESPONSE_free(response);
  if (!found) return ocsp_fail(self, 75, "OCSP response does not cover the peer certificate");
  if (!valid_time) return ocsp_fail(self, 99, "OCSP response is outside its validity window");
  if (status == 1) return ocsp_fail(self, 23, "peer certificate is revoked by OCSP");
  if (status != 0) return ocsp_fail(self, 75, "OCSP responder returned certificate unknown");
  return 1;
}

MOONBIT_FFI_EXPORT int moon_http_tls_ready(HttpTls *self) { return self->initialized == 1; }
MOONBIT_FFI_EXPORT void *moon_http_tls_ssl_handle(HttpTls *self) { return self->ssl; }
MOONBIT_FFI_EXPORT void *moon_http_tls_library_handle(void) {
  ensure_tls_loaded();
  return tls_library;
}
MOONBIT_FFI_EXPORT int moon_http_tls_available(HttpTls *self) { return self->initialized >= 0; }
MOONBIT_FFI_EXPORT void moon_http_tls_close(HttpTls *self) { release_tls(self); }
MOONBIT_FFI_EXPORT uint64_t moon_http_tls_error_code(HttpTls *self) { return self->error_code; }
MOONBIT_FFI_EXPORT int64_t moon_http_tls_verify_code(HttpTls *self) { return self->verify_code; }
MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_tls_error_message(HttpTls *self) {
  int n = (int)strlen(self->error); moonbit_bytes_t out = moonbit_make_bytes(n, 0); memcpy(out, self->error, n); return out;
}

static int step_result(HttpTls *self, int ret) {
  if (ret > 0) return 1;
  int status = p_SSL_get_error(self->ssl, ret);
  if (status == 2 || status == 3 || status == 6) return status;
  capture_error(self, "OpenSSL protocol operation failed"); return -1;
}
MOONBIT_FFI_EXPORT int moon_http_tls_handshake(HttpTls *self) {
  if (self->initialized != 1) return -1;
  p_ERR_clear_error(); return step_result(self, p_SSL_do_handshake(self->ssl));
}
MOONBIT_FFI_EXPORT int moon_http_tls_feed(HttpTls *self, moonbit_bytes_t bytes) {
  if (self->initialized != 1) return -1;
  return p_BIO_write(self->input, bytes, Moonbit_array_length(bytes));
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_tls_drain(HttpTls *self) {
  size_t size = self->initialized == 1 ? p_BIO_ctrl_pending(self->output) : 0;
  if (size > 16384) size = 16384;
  moonbit_bytes_t out = moonbit_make_bytes((int)size, 0);
  if (size) p_BIO_read(self->output, out, (int)size);
  return out;
}
MOONBIT_FFI_EXPORT int moon_http_tls_read(HttpTls *self, moonbit_bytes_t bytes, int *count) {
  *count = 0;
  if (self->initialized != 1) return -1;
  p_ERR_clear_error();
  int ret = p_SSL_read(self->ssl, bytes, Moonbit_array_length(bytes));
  if (ret > 0) *count = ret;
  return step_result(self, ret);
}
MOONBIT_FFI_EXPORT int moon_http_tls_write(HttpTls *self, moonbit_bytes_t bytes, int offset, int length, int *count) {
  *count = 0;
  if (self->initialized != 1 || offset < 0 || length < 0 || offset > Moonbit_array_length(bytes) - length) return -1;
  p_ERR_clear_error();
  int ret = p_SSL_write(self->ssl, bytes + offset, length);
  if (ret > 0) *count = ret;
  return step_result(self, ret);
}
MOONBIT_FFI_EXPORT int moon_http_tls_version(HttpTls *self) {
  return self->initialized == 1 ? p_SSL_version(self->ssl) : 0;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_tls_cipher(HttpTls *self) {
  const char *name = "";
  if (self->initialized == 1) { const SSL_CIPHER *cipher = p_SSL_get_current_cipher(self->ssl); if (cipher) name = p_SSL_CIPHER_standard_name(cipher); }
  if (!name) name = "";
  int n = (int)strlen(name); moonbit_bytes_t out = moonbit_make_bytes(n, 0); memcpy(out, name, n); return out;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_tls_alpn(HttpTls *self) {
  const unsigned char *data = NULL; unsigned int n = 0;
  if (self->initialized == 1) p_SSL_get0_alpn_selected(self->ssl, &data, &n);
  moonbit_bytes_t out = moonbit_make_bytes((int)n, 0); if (n) memcpy(out, data, n); return out;
}
MOONBIT_FFI_EXPORT int moon_http_tls_peer_authenticated(HttpTls *self) {
  if (self->initialized != 1 || p_SSL_get_verify_result(self->ssl) != 0) return 0;
  X509 *peer = p_SSL_get1_peer_certificate(self->ssl);
  if (!peer) return 0;
  p_X509_free(peer); return 1;
}
