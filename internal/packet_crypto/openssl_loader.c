/* Select and retain one OpenSSL 3 library pair for packet protection and TLS. */
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#else
#include <dlfcn.h>
#include <pthread.h>
#endif
#ifdef _WIN32
static INIT_ONCE tls_once = INIT_ONCE_STATIC_INIT;
typedef HMODULE TlsModule;
#else
static pthread_once_t tls_once = PTHREAD_ONCE_INIT;
typedef void *TlsModule;
#endif
static TlsModule tls_library = NULL;
static TlsModule crypto_library = NULL;


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
  TlsModule ssl = NULL, crypto = NULL;
  if (!load_modules(&ssl, &crypto)) return;
  typedef unsigned long (*Version)(void);
  Version version = (Version)find_symbol(ssl, crypto, "OpenSSL_version_num");
  if (!version || version() < 0x30000000UL) { close_modules(ssl, crypto); return; }
  tls_library = ssl;
  crypto_library = crypto;
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

MOONBIT_FFI_EXPORT int moon_http_random_fill(uint8_t *buffer) {
  int length = Moonbit_array_length(buffer);
  if (length == 0) return 1;
  typedef int (*RandomBytes)(unsigned char *, int);
  RandomBytes generate = (RandomBytes)moon_http_tls_symbol("RAND_bytes");
  return generate != NULL && generate(buffer, length) == 1;
}

MOONBIT_FFI_EXPORT void *moon_http_tls_library_handle(void) {
  ensure_tls_loaded();
  return tls_library;
}
