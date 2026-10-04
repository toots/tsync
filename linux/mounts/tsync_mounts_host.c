#define CAML_NAME_SPACE
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <stdlib.h>
#include <string.h>

#include "tsync_mounts.h"

typedef struct {
  char *mount_point;
  size_t mount_point_length;
  char *socket;
  size_t socket_length;
} pair;

static char *copy_string(value _string, size_t *length) {
  *length = caml_string_length(_string);
  char *copy = malloc(*length + 1);
  if (copy != NULL) {
    memcpy(copy, String_val(_string), *length);
    copy[*length] = 0;
  }
  return copy;
}

/* The list is walked without allocating on the OCaml heap, so it needs no
   root; emit runs only once every string is copied out. */
int tsync_mounts_query(tsync_mount_emit emit, void *context) {
  static int started = 0;
  if (!started) {
    char *arguments[] = {"tsync_mounts", NULL};
    caml_startup(arguments);
    started = 1;
  }
  const value *entry = caml_named_value("tsync_mount_points");
  if (entry == NULL)
    return -1;
  value _answer = caml_callback_exn(*entry, Val_unit);
  if (Is_exception_result(_answer))
    return 0;
  size_t count = 0;
  for (value _cell = _answer; _cell != Val_emptylist; _cell = Field(_cell, 1))
    count++;
  pair *pairs = calloc(count ? count : 1, sizeof(pair));
  if (pairs == NULL)
    return 0;
  size_t copied = 0;
  for (value _cell = _answer; _cell != Val_emptylist; _cell = Field(_cell, 1)) {
    value _pair = Field(_cell, 0);
    pair *p = &pairs[copied];
    p->mount_point = copy_string(Field(_pair, 0), &p->mount_point_length);
    p->socket = copy_string(Field(_pair, 1), &p->socket_length);
    if (p->mount_point == NULL || p->socket == NULL) {
      free(p->mount_point);
      free(p->socket);
      break;
    }
    copied++;
  }
  for (size_t i = 0; i < copied; i++) {
    emit(context, pairs[i].mount_point, pairs[i].mount_point_length,
         pairs[i].socket, pairs[i].socket_length);
    free(pairs[i].mount_point);
    free(pairs[i].socket);
  }
  free(pairs);
  return (int)copied;
}
