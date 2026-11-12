#define CAML_NAME_SPACE
#include <os/log.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "tsync_ios.h"

CAMLprim value tsync_ios_log_write(value _level, value _message) {
  static const os_log_type_t types[] = {OS_LOG_TYPE_DEBUG, OS_LOG_TYPE_INFO,
                                        OS_LOG_TYPE_DEFAULT, OS_LOG_TYPE_ERROR};
  os_log_with_type(OS_LOG_DEFAULT, types[Int_val(_level)], "%{public}s",
                   String_val(_message));
  return Val_unit;
}

/* Module initialisers derive paths from the environment as they run, and
   the core reads it on later calls, so it is set once, before the runtime
   starts. */
static pthread_mutex_t start_lock = PTHREAD_MUTEX_INITIALIZER;
static int runtime_started;

void tsync_ios_start(const char *home, const char *config_file,
                     const char *transfer_root, long minor_heap_words,
                     long workers, long may_block, long release_growth) {
  pthread_mutex_lock(&start_lock);
  if (!runtime_started) {
    setenv("HOME", home, 1);
    setenv("TSYNC_CONFIG_FILE", config_file, 1);
    if (minor_heap_words > 0) {
      char parameters[32];
      snprintf(parameters, sizeof parameters, "s=%ld", minor_heap_words);
      setenv("OCAMLRUNPARAM", parameters, 0);
    }
    char *argv[] = {"tsync", NULL};
    caml_startup(argv);
    tsync_bridge_started();
    caml_release_runtime_system();
    tsync_bridge_init(NULL, transfer_root, workers, may_block, release_growth);
    runtime_started = 1;
  }
  pthread_mutex_unlock(&start_lock);
}
