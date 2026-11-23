#ifndef MOON_HTTP_OPENSSL_SYMBOLS_H
#define MOON_HTTP_OPENSSL_SYMBOLS_H
/* Process-lifetime lookup for the selected libssl/libcrypto pair. Callers
 * receive this table through their constructor, including standalone linkers. */
typedef struct {
  void *(*lookup)(const char *);
} HttpOpenSslSymbols;
#endif
