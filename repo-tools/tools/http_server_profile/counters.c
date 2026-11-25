#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <stdatomic.h>
#include <sys/mman.h>

enum { ALLOC_CALLS, ALLOC_BYTES, COPY_CALLS, COPY_BYTES, LOCK_WAITS, LOCK_NS,
       FLOW_WAITS, FLOW_NS, DATA_WRITES, SLOTS };
static _Atomic uint64_t fallback[SLOTS];
static _Atomic uint64_t *counters = fallback;

__attribute__((constructor)) static void setup(void) {
  const char *path = getenv("HTTP_PROFILE_COUNTERS");
  if (!path) return;
  int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
  if (fd < 0 || ftruncate(fd, sizeof(fallback)) != 0) abort();
  void *memory = mmap(NULL, sizeof(fallback), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (memory == MAP_FAILED) abort();
  close(fd);
  counters = memory;
}
static void add(unsigned slot, uint64_t value) {
  atomic_fetch_add_explicit(&counters[slot], value, memory_order_relaxed);
}
void r4_record_alloc(size_t bytes) { add(ALLOC_CALLS, 1); add(ALLOC_BYTES, bytes); }
void r4_record_copy(size_t bytes) { add(COPY_CALLS, 1); add(COPY_BYTES, bytes); }
uint64_t r4_nanoseconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000 + (uint64_t)ts.tv_nsec;
}
void r4_locked(uint64_t began) { add(LOCK_WAITS, 1); add(LOCK_NS, r4_nanoseconds()-began); }
void r4_credited(uint64_t began) { add(FLOW_WAITS, 1); add(FLOW_NS, r4_nanoseconds()-began); }
void r4_wrote(void) { add(DATA_WRITES, 1); }
