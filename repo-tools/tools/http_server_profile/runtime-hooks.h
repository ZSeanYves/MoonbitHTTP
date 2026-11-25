extern void r4_record_alloc(size_t);
extern void r4_record_copy(size_t);
static void *r4_alloc(size_t len) { r4_record_alloc(len); return MOONBIT_MALLOC_RAW(len); }
static void *r4_copy(void *to, const void *from, size_t n) {
  r4_record_copy(n); return memcpy(to, from, n);
}
static void *r4_move(void *to, const void *from, size_t n) {
  r4_record_copy(n); return memmove(to, from, n);
}
#undef MOONBIT_MALLOC_RAW
#define MOONBIT_MALLOC_RAW r4_alloc
#undef memcpy
#undef memmove
#define memcpy r4_copy
#define memmove r4_move
