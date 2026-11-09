/* Bridge calls each from a new thread that ends right after it. */
#define CAML_NAME_SPACE
#include <pthread.h>
#include <stdlib.h>

#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "tsync_bridge.h"

static void *call_and_end(void *unused) {
  (void)unused;
  size_t length = 0;
  free(tsync_bridge_text("check_config", "docs", 4, &length));
  return NULL;
}

CAMLprim value tsync_test_calls_on_ended_threads(value _calls) {
  CAMLparam1(_calls);
  long calls = Long_val(_calls), failures = 0;
  caml_release_runtime_system();
  for (long i = 0; i < calls; i++) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, call_and_end, NULL) != 0 ||
        pthread_join(thread, NULL) != 0)
      failures++;
  }
  caml_acquire_runtime_system();
  CAMLreturn(Val_long(failures));
}
