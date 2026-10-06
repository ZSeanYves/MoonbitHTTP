/* White-box fixture construction only: the MoonBit declarations live in
 * revocation_wbtest.mbt. This does not replace or change verification time.
 * Resolve signing functions lazily, so production TLS has no signing-symbol
 * dependency. All inputs are borrowed; all output is copied into MoonBit. */
#include <moonbit.h>
#include <stddef.h>
#include <string.h>
#include <time.h>

typedef struct bio_st BIO;
typedef struct bio_method_st BIO_METHOD;
typedef struct x509_st X509;
typedef struct X509_name_st X509_NAME;
typedef struct x509_crl_st X509_CRL;
typedef struct x509_revoked_st X509_REVOKED;
typedef struct evp_pkey_st EVP_PKEY;
typedef struct evp_md_st EVP_MD;
typedef struct asn1_string_st ASN1_TIME;
typedef struct asn1_string_st ASN1_INTEGER;
typedef struct ocsp_basic_response_st OCSP_BASICRESP;
typedef struct ocsp_response_st OCSP_RESPONSE;
typedef struct ocsp_cert_id_st OCSP_CERTID;
typedef struct ocsp_single_response_st OCSP_SINGLERESP;
typedef int (*TlsPemPasswordCallback)(char *, int, int, void *);
extern void *moon_http_tls_symbol(const char *);

#define FIXTURE_SYMBOLS(F) \
  F(BIO *, BIO_new_mem_buf, (const void *, int)) \
  F(const BIO_METHOD *, BIO_s_mem, (void)) \
  F(BIO *, BIO_new, (const BIO_METHOD *)) \
  F(int, BIO_free, (BIO *)) \
  F(int, BIO_read, (BIO *, void *, int)) \
  F(size_t, BIO_ctrl_pending, (BIO *)) \
  F(X509 *, PEM_read_bio_X509, (BIO *, X509 **, TlsPemPasswordCallback, void *)) \
  F(EVP_PKEY *, PEM_read_bio_PrivateKey, (BIO *, EVP_PKEY **, TlsPemPasswordCallback, void *)) \
  F(int, PEM_write_bio_X509_CRL, (BIO *, const X509_CRL *)) \
  F(void, X509_free, (X509 *)) \
  F(void, EVP_PKEY_free, (EVP_PKEY *)) \
  F(X509_NAME *, X509_get_subject_name, (const X509 *)) \
  F(ASN1_INTEGER *, X509_get_serialNumber, (X509 *)) \
  F(const EVP_MD *, EVP_sha1, (void)) \
  F(const EVP_MD *, EVP_sha256, (void)) \
  F(ASN1_TIME *, ASN1_TIME_adj, (ASN1_TIME *, time_t, int, long)) \
  F(void, ASN1_TIME_free, (ASN1_TIME *)) \
  F(OCSP_BASICRESP *, OCSP_BASICRESP_new, (void)) \
  F(void, OCSP_BASICRESP_free, (OCSP_BASICRESP *)) \
  F(OCSP_CERTID *, OCSP_cert_to_id, (const EVP_MD *, const X509 *, const X509 *)) \
  F(void, OCSP_CERTID_free, (OCSP_CERTID *)) \
  F(OCSP_SINGLERESP *, OCSP_basic_add1_status, (OCSP_BASICRESP *, OCSP_CERTID *, int, int, ASN1_TIME *, ASN1_TIME *, ASN1_TIME *)) \
  F(int, OCSP_basic_sign, (OCSP_BASICRESP *, X509 *, EVP_PKEY *, const EVP_MD *, void *, unsigned long)) \
  F(OCSP_RESPONSE *, OCSP_response_create, (int, OCSP_BASICRESP *)) \
  F(void, OCSP_RESPONSE_free, (OCSP_RESPONSE *)) \
  F(int, i2d_OCSP_RESPONSE, (const OCSP_RESPONSE *, unsigned char **)) \
  F(X509_CRL *, X509_CRL_new, (void)) \
  F(void, X509_CRL_free, (X509_CRL *)) \
  F(int, X509_CRL_set_version, (X509_CRL *, long)) \
  F(int, X509_CRL_set_issuer_name, (X509_CRL *, const X509_NAME *)) \
  F(int, X509_CRL_set1_lastUpdate, (X509_CRL *, const ASN1_TIME *)) \
  F(int, X509_CRL_set1_nextUpdate, (X509_CRL *, const ASN1_TIME *)) \
  F(X509_REVOKED *, X509_REVOKED_new, (void)) \
  F(void, X509_REVOKED_free, (X509_REVOKED *)) \
  F(int, X509_REVOKED_set_serialNumber, (X509_REVOKED *, ASN1_INTEGER *)) \
  F(int, X509_REVOKED_set_revocationDate, (X509_REVOKED *, ASN1_TIME *)) \
  F(int, X509_CRL_add0_revoked, (X509_CRL *, X509_REVOKED *)) \
  F(int, X509_CRL_sort, (X509_CRL *)) \
  F(int, X509_CRL_sign, (X509_CRL *, EVP_PKEY *, const EVP_MD *))

typedef struct {
#define DECLARE_FIXTURE_SYMBOL(ret, name, args) ret (*name) args;
  FIXTURE_SYMBOLS(DECLARE_FIXTURE_SYMBOL)
#undef DECLARE_FIXTURE_SYMBOL
} FixtureApi;

static int fixture_api(FixtureApi *api) {
#define LOAD_FIXTURE_SYMBOL(ret, name, args) \
  api->name = (ret (*) args)moon_http_tls_symbol(#name); \
  if (!api->name) return 0;
  FIXTURE_SYMBOLS(LOAD_FIXTURE_SYMBOL)
#undef LOAD_FIXTURE_SYMBOL
  return 1;
}

static int fixture_no_password(char *buffer, int size, int writing, void *data) {
  (void)buffer; (void)size; (void)writing; (void)data;
  return 0;
}

static X509 *fixture_cert(FixtureApi *api, moonbit_bytes_t pem) {
  BIO *bio = api->BIO_new_mem_buf(pem, Moonbit_array_length(pem));
  if (!bio) return NULL;
  X509 *cert = api->PEM_read_bio_X509(bio, NULL, NULL, NULL);
  api->BIO_free(bio);
  return cert;
}

static EVP_PKEY *fixture_key(FixtureApi *api, moonbit_bytes_t pem) {
  BIO *bio = api->BIO_new_mem_buf(pem, Moonbit_array_length(pem));
  if (!bio) return NULL;
  EVP_PKEY *key = api->PEM_read_bio_PrivateKey(bio, NULL, fixture_no_password, NULL);
  api->BIO_free(bio);
  return key;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_test_ocsp(
    moonbit_bytes_t subject_pem, moonbit_bytes_t issuer_pem,
    moonbit_bytes_t key_pem, int status, int this_offset, int next_offset,
    int omit_next, int corrupt_signature) {
  FixtureApi api;
  if (!fixture_api(&api)) return moonbit_make_bytes(0, 0);
  X509 *subject = fixture_cert(&api, subject_pem);
  X509 *issuer = fixture_cert(&api, issuer_pem);
  EVP_PKEY *key = fixture_key(&api, key_pem);
  OCSP_BASICRESP *basic = NULL;
  OCSP_RESPONSE *response = NULL;
  OCSP_CERTID *id = NULL;
  ASN1_TIME *this_update = NULL, *next_update = NULL, *revoked_at = NULL;
  moonbit_bytes_t result = NULL;
  time_t now = time(NULL);
  if (!subject || !issuer || !key || now == (time_t)-1) goto done;
  this_update = api.ASN1_TIME_adj(NULL, now, 0, (long)this_offset);
  if (!omit_next) next_update = api.ASN1_TIME_adj(NULL, now, 0, (long)next_offset);
  revoked_at = api.ASN1_TIME_adj(NULL, now, -1, 0);
  basic = api.OCSP_BASICRESP_new();
  id = api.OCSP_cert_to_id(api.EVP_sha1(), subject, issuer);
  if (!this_update || (!omit_next && !next_update) || !revoked_at || !basic || !id) goto done;
  if (!api.OCSP_basic_add1_status(basic, id, status, 0,
      status == 1 ? revoked_at : NULL, this_update, next_update)) goto done;
  /* OCSP_NOCERTS: the verifier must find this issuer in the real peer chain.
   * With no embedded certificates, the final DER byte belongs to the response
   * signature; changing it tests signature validation, not malformed DER. */
  if (api.OCSP_basic_sign(basic, issuer, key, api.EVP_sha256(), NULL, 1UL) != 1) goto done;
  response = api.OCSP_response_create(0, basic);
  if (!response) goto done;
  int length = api.i2d_OCSP_RESPONSE(response, NULL);
  if (length <= 0) goto done;
  result = moonbit_make_bytes(length, 0);
  unsigned char *cursor = result;
  if (api.i2d_OCSP_RESPONSE(response, &cursor) != length || cursor != result + length) {
    moonbit_decref(result); result = NULL; goto done;
  }
  if (corrupt_signature) result[length - 1] ^= 1;
done:
  if (id) api.OCSP_CERTID_free(id);
  if (response) api.OCSP_RESPONSE_free(response);
  if (basic) api.OCSP_BASICRESP_free(basic);
  if (this_update) api.ASN1_TIME_free(this_update);
  if (next_update) api.ASN1_TIME_free(next_update);
  if (revoked_at) api.ASN1_TIME_free(revoked_at);
  if (key) api.EVP_PKEY_free(key);
  if (issuer) api.X509_free(issuer);
  if (subject) api.X509_free(subject);
  return result ? result : moonbit_make_bytes(0, 0);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_test_crl(
    moonbit_bytes_t issuer_pem, moonbit_bytes_t key_pem,
    moonbit_bytes_t revoked_pem, int this_offset, int next_offset) {
  FixtureApi api;
  if (!fixture_api(&api)) return moonbit_make_bytes(0, 0);
  X509 *issuer = fixture_cert(&api, issuer_pem);
  X509 *revoked_cert = Moonbit_array_length(revoked_pem) ? fixture_cert(&api, revoked_pem) : NULL;
  EVP_PKEY *key = fixture_key(&api, key_pem);
  X509_CRL *crl = NULL;
  X509_REVOKED *revoked = NULL;
  ASN1_TIME *this_update = NULL, *next_update = NULL, *revoked_at = NULL;
  BIO *output = NULL;
  moonbit_bytes_t result = NULL;
  time_t now = time(NULL);
  if (!issuer || !key || (Moonbit_array_length(revoked_pem) && !revoked_cert) || now == (time_t)-1) goto done;
  this_update = api.ASN1_TIME_adj(NULL, now, 0, (long)this_offset);
  next_update = api.ASN1_TIME_adj(NULL, now, 0, (long)next_offset);
  revoked_at = api.ASN1_TIME_adj(NULL, now, -1, 0);
  crl = api.X509_CRL_new();
  if (!crl || !this_update || !next_update || !revoked_at) goto done;
  if (api.X509_CRL_set_version(crl, 1L) != 1 ||
      api.X509_CRL_set_issuer_name(crl, api.X509_get_subject_name(issuer)) != 1 ||
      api.X509_CRL_set1_lastUpdate(crl, this_update) != 1 ||
      api.X509_CRL_set1_nextUpdate(crl, next_update) != 1) goto done;
  if (revoked_cert) {
    revoked = api.X509_REVOKED_new();
    if (!revoked ||
        api.X509_REVOKED_set_serialNumber(revoked, api.X509_get_serialNumber(revoked_cert)) != 1 ||
        api.X509_REVOKED_set_revocationDate(revoked, revoked_at) != 1 ||
        api.X509_CRL_add0_revoked(crl, revoked) != 1) goto done;
    revoked = NULL; /* The CRL owns the successful add0 transfer. */
  }
  if (api.X509_CRL_sort(crl) != 1 || api.X509_CRL_sign(crl, key, api.EVP_sha256()) <= 0) goto done;
  output = api.BIO_new(api.BIO_s_mem());
  if (!output || api.PEM_write_bio_X509_CRL(output, crl) != 1) goto done;
  size_t length = api.BIO_ctrl_pending(output);
  if (!length || length > 0x7fffffffU) goto done;
  result = moonbit_make_bytes((int)length, 0);
  if (api.BIO_read(output, result, (int)length) != (int)length) {
    moonbit_decref(result); result = NULL;
  }
done:
  if (output) api.BIO_free(output);
  if (revoked) api.X509_REVOKED_free(revoked);
  if (crl) api.X509_CRL_free(crl);
  if (this_update) api.ASN1_TIME_free(this_update);
  if (next_update) api.ASN1_TIME_free(next_update);
  if (revoked_at) api.ASN1_TIME_free(revoked_at);
  if (key) api.EVP_PKEY_free(key);
  if (issuer) api.X509_free(issuer);
  if (revoked_cert) api.X509_free(revoked_cert);
  return result ? result : moonbit_make_bytes(0, 0);
}
