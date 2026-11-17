#define CAML_NAME_SPACE
#include <fcntl.h>
#include <os/log.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "tsync_ios.h"

static char *core_log, *core_old_log;
static const off_t core_log_limit = 1 << 20;

/* The log, opened for appending and locked against the other process. */
static int open_core_log(void) {
  int descriptor = open(core_log, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
  if (descriptor >= 0 && flock(descriptor, LOCK_EX) != 0) {
    close(descriptor);
    return -1;
  }
  return descriptor;
}

/* Each line of [message] after [prefix]. */
static char *prefixed_lines(const char *prefix, const char *message, size_t *size) {
  char *text = NULL;
  FILE *out = open_memstream(&text, size);
  if (out == NULL)
    return NULL;
  const char *start = message;
  do {
    const char *newline = strchr(start, '\n');
    int length = newline ? (int)(newline - start) : (int)strlen(start);
    fprintf(out, "%s%.*s\n", prefix, length, start);
    start = newline ? newline + 1 : NULL;
  } while (start != NULL && *start != '\0');
  fclose(out);
  return text;
}

/* ios.md §4. One write per message under the log's flock, so that the
   app's and the extension's lines do not interleave; the rotation renames
   only the file still named tsync.log, so that a process that locked the
   half just rotated does not rotate again. */
static void append_core_log(int level, const char *message) {
  static const char *names[] = {"debug", "info", "warn", "err"};
  char *prefix = NULL, *text = NULL;
  size_t size = 0;
  int descriptor = -1;
  if (core_log == NULL)
    return;
  time_t now = time(NULL);
  struct tm local;
  localtime_r(&now, &local);
  if (asprintf(&prefix, "%02d:%02d:%02d %s %s[%d] ", local.tm_hour,
               local.tm_min, local.tm_sec, names[level], getprogname(),
               getpid()) < 0)
    goto end;
  text = prefixed_lines(prefix, message, &size);
  if (text == NULL)
    goto end;
  descriptor = open_core_log();
  if (descriptor < 0)
    goto end;
  struct stat opened, named;
  if (fstat(descriptor, &opened) == 0 && opened.st_size >= core_log_limit &&
      stat(core_log, &named) == 0 && named.st_ino == opened.st_ino &&
      named.st_dev == opened.st_dev) {
    rename(core_log, core_old_log);
    close(descriptor);
    descriptor = open_core_log();
    if (descriptor < 0)
      goto end;
  }
  write(descriptor, text, size);
end:
  if (descriptor >= 0)
    close(descriptor);
  free(text);
  free(prefix);
}

CAMLprim value tsync_ios_log_write(value _level, value _message) {
  static const os_log_type_t types[] = {OS_LOG_TYPE_DEBUG, OS_LOG_TYPE_INFO,
                                        OS_LOG_TYPE_DEFAULT, OS_LOG_TYPE_ERROR};
  int level = Int_val(_level);
  os_log_with_type(OS_LOG_DEFAULT, types[level], "%{public}s",
                   String_val(_message));
  append_core_log(level, String_val(_message));
  return Val_unit;
}

/* Module initialisers derive paths from the environment as they run, and
   the core reads it on later calls, so it is set once, before the runtime
   starts. */
static pthread_mutex_t start_lock = PTHREAD_MUTEX_INITIALIZER;
static int runtime_started;

void tsync_ios_start(const char *home, const char *config_file,
                     const char *log_file, const char *transfer_root,
                     long minor_heap_words, long workers, long may_block,
                     long release_growth) {
  pthread_mutex_lock(&start_lock);
  if (!runtime_started) {
    core_log = strdup(log_file);
    asprintf(&core_old_log, "%.*s.old.log",
             (int)(strlen(log_file) - strlen(".log")), log_file);
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
