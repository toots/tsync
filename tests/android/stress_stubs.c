/* Reads through the bridge from threads the OCaml runtime did not create. */
#define CAML_NAME_SPACE
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "tsync_bridge.h"

CAMLprim value tsync_test_open_before_start(value _unit) {
  return Val_long(tsync_bridge_open("root", 4));
}

CAMLprim value tsync_test_started(value _unit) {
  tsync_bridge_started();
  return Val_unit;
}

struct reader {
  char ref[64];
  long reads, size;
  atomic_long *failures;
  int seed;
};

/* The content's byte at each offset, as the test wrote it. */
static unsigned char expected(long offset) { return (offset * 7 + 3) & 0xff; }

static void *read_loop(void *arg) {
  struct reader *reader = arg;
  char buffer[4096];
  long handle = tsync_bridge_open(reader->ref, strlen(reader->ref));
  if (handle <= 0 || tsync_bridge_size(handle) != reader->size) {
    atomic_fetch_add(reader->failures, 1);
    return NULL;
  }
  unsigned state = reader->seed;
  for (long i = 0; i < reader->reads; i++) {
    state = state * 1103515245u + 12345u;
    long offset = state % reader->size;
    long want = reader->size - offset < (long)sizeof buffer
                    ? reader->size - offset
                    : (long)sizeof buffer;
    long served = tsync_bridge_read(handle, offset, sizeof buffer, buffer);
    int exact = served == want;
    for (long j = 0; exact && j < served; j++)
      exact = (unsigned char)buffer[j] == expected(offset + j);
    if (!exact)
      atomic_fetch_add(reader->failures, 1);
  }
  tsync_bridge_close(handle);
  if (tsync_bridge_read(handle, 0, sizeof buffer, buffer) != -EBADF)
    atomic_fetch_add(reader->failures, 1);
  return NULL;
}

/* The threads end while the runtime is up, so each one unregisters. */
CAMLprim value tsync_test_stress(value _ref, value _threads, value _reads,
                                 value _size) {
  CAMLparam4(_ref, _threads, _reads, _size);
  enum { most = 64 };
  long threads = Long_val(_threads) > most ? most : Long_val(_threads);
  pthread_t ids[most];
  struct reader readers[most];
  atomic_long failures = 0;
  for (long i = 0; i < threads; i++) {
    strncpy(readers[i].ref, String_val(_ref), sizeof readers[i].ref - 1);
    readers[i].ref[sizeof readers[i].ref - 1] = 0;
    readers[i].reads = Long_val(_reads);
    readers[i].size = Long_val(_size);
    readers[i].failures = &failures;
    readers[i].seed = i + 1;
  }
  caml_release_runtime_system();
  for (long i = 0; i < threads; i++)
    pthread_create(&ids[i], NULL, read_loop, &readers[i]);
  for (long i = 0; i < threads; i++)
    pthread_join(ids[i], NULL);
  caml_acquire_runtime_system();
  CAMLreturn(Val_long(atomic_load(&failures)));
}
