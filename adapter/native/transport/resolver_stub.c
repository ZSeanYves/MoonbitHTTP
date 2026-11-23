/* getaddrinfo may block in NSS. A bounded number of workers own only C data,
 * so cancellation can release the caller immediately, even during a lookup. */
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#else
#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#endif
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  char *host;
  struct addrinfo *list, *next;
  int done, abandoned, error;
} Lookup;
typedef struct { Lookup *job; int busy; } Handle;
static unsigned workers;
#ifdef _WIN32
static SRWLOCK mutex = SRWLOCK_INIT;
#define LOCK() AcquireSRWLockExclusive(&mutex)
#define UNLOCK() ReleaseSRWLockExclusive(&mutex)
#else
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
#define LOCK() pthread_mutex_lock(&mutex)
#define UNLOCK() pthread_mutex_unlock(&mutex)
#endif

static void dispose(Lookup *job) {
  if (job->list) freeaddrinfo(job->list);
  free(job->host);
  free(job);
}
static void release(void *object) {
  Handle *handle = object;
  Lookup *job = handle->job;
  if (!job) return;
  handle->job = NULL;
  LOCK();
  int done = job->done;
  job->abandoned = 1;
  UNLOCK();
  if (done) dispose(job);
}

#ifdef _WIN32
static DWORD WINAPI resolve_worker(void *arg) {
#else
static void *resolve_worker(void *arg) {
#endif
  Lookup *job = arg;
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
#ifdef _WIN32
  WSADATA data;
  job->error = WSAStartup(MAKEWORD(2, 2), &data);
  if (!job->error) {
    job->error = getaddrinfo(job->host, NULL, &hints, &job->list);
    WSACleanup();
  }
#else
  job->error = getaddrinfo(job->host, NULL, &hints, &job->list);
#endif
  job->next = job->list;
  LOCK();
  workers--;
  job->done = 1;
  int abandoned = job->abandoned;
  UNLOCK();
  if (abandoned) dispose(job);
  return 0;
}

MOONBIT_FFI_EXPORT Handle *moon_http_lookup_start(uint8_t *host) {
  Handle *handle = moonbit_make_external_object(release, sizeof(Handle));
  handle->job = NULL;
  handle->busy = 0;
  size_t n = Moonbit_array_length(host);
  if (!n || memchr(host, 0, n)) return handle;
  LOCK();
  if (workers >= 16) { handle->busy = 1; UNLOCK(); return handle; }
  workers++;
  UNLOCK();
  Lookup *job = calloc(1, sizeof(*job));
  if (job && (job->host = malloc(n + 1))) {
    memcpy(job->host, host, n);
    job->host[n] = 0;
#ifdef _WIN32
    HANDLE thread = CreateThread(NULL, 0, resolve_worker, job, 0, NULL);
    if (thread) { CloseHandle(thread); handle->job = job; return handle; }
#else
    pthread_t thread;
    if (!pthread_create(&thread, NULL, resolve_worker, job)) {
      pthread_detach(thread); handle->job = job; return handle;
    }
#endif
  }
  if (job) dispose(job);
  LOCK(); workers--; UNLOCK();
  return handle;
}

MOONBIT_FFI_EXPORT int moon_http_lookup_status(Handle *handle) {
  if (!handle->job) return handle->busy ? -2 : -1;
  LOCK();
  int done = handle->job->done;
  UNLOCK();
  return done;
}
MOONBIT_FFI_EXPORT int moon_http_lookup_error(Handle *handle) {
  return handle->job->error;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_lookup_message(Handle *handle) {
#ifdef _WIN32
  const char *text = gai_strerrorA(handle->job->error);
#else
  const char *text = gai_strerror(handle->job->error);
#endif
  if (!text) text = "getaddrinfo failed";
  int n = (int)strlen(text);
  moonbit_bytes_t result = moonbit_make_bytes(n, 0);
  memcpy(result, text, n);
  return result;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t moon_http_lookup_next(Handle *handle) {
  Lookup *job = handle->job;
  while (job->next) {
    const struct addrinfo *item = job->next;
    job->next = item->ai_next;
    const void *address;
    if (item->ai_family == AF_INET) {
      address = &((struct sockaddr_in *)item->ai_addr)->sin_addr;
    } else if (item->ai_family == AF_INET6 && !((struct sockaddr_in6 *)item->ai_addr)->sin6_scope_id) {
      address = &((struct sockaddr_in6 *)item->ai_addr)->sin6_addr;
    } else continue;
    char text[INET6_ADDRSTRLEN];
    if (inet_ntop(item->ai_family, address, text, sizeof(text))) {
      int n = (int)strlen(text);
      moonbit_bytes_t result = moonbit_make_bytes(n, 0);
      memcpy(result, text, n);
      return result;
    }
  }
  return moonbit_make_bytes(0, 0);
}
MOONBIT_FFI_EXPORT void moon_http_lookup_release(Handle *handle) { release(handle); }
