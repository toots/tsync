#define CAML_NAME_SPACE
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "tsync_bridge.h"

/* What a thread is to the runtime. A thread the bridge registered owes an
   unregistration when it dies: the runtime would otherwise scan a stack that
   no longer exists. The thread that started the runtime must never be
   registered. */
static char runtime_thread, foreign_thread;
static pthread_key_t thread_kind;
static pthread_once_t thread_kind_once = PTHREAD_ONCE_INIT;
static atomic_bool started;

static void thread_exits(void *kind) {
  if (kind == &foreign_thread)
    caml_c_thread_unregister();
}

static void make_thread_kind(void) {
  pthread_key_create(&thread_kind, thread_exits);
}

void tsync_bridge_started(void) {
  pthread_once(&thread_kind_once, make_thread_kind);
  pthread_setspecific(thread_kind, &runtime_thread);
  atomic_store(&started, 1);
}

/* Registration returns with the runtime lock released, so the acquisition
   that follows is not optional. An unregistered thread has no runtime state
   and would crash at its first blocking section instead of failing. */
static void enter_ocaml(void) {
  pthread_once(&thread_kind_once, make_thread_kind);
  if (pthread_getspecific(thread_kind) == NULL) {
    if (!caml_c_thread_register())
      abort();
    pthread_setspecific(thread_kind, &foreign_thread);
  }
  caml_acquire_runtime_system();
}

static void leave_ocaml(void) { caml_release_runtime_system(); }

static const value *entry(const char *name) {
  char full[64];
  snprintf(full, sizeof full, "tsync_%s", name);
  const value *closure = caml_named_value(full);
  if (closure == NULL)
    abort();
  return closure;
}

char *tsync_bridge_text(const char *name, const char *arg, size_t arg_length,
                        size_t *length) {
  if (!atomic_load(&started))
    return NULL;
  enter_ocaml();
  CAMLparam0();
  CAMLlocal2(_arg, _result);
  char *text = NULL;
  _arg = caml_alloc_initialized_string(arg_length, arg);
  _result = caml_callback_exn(*entry(name), _arg);
  if (!Is_exception_result(_result)) {
    *length = caml_string_length(_result);
    text = malloc(*length + 1);
    if (text != NULL) {
      memcpy(text, String_val(_result), *length);
      text[*length] = 0;
    }
  }
  CAMLdrop;
  leave_ocaml();
  return text;
}

void tsync_bridge_init(const char *trust_store, const char *transfer_root) {
  enter_ocaml();
  CAMLparam0();
  CAMLlocal2(_trust_store, _transfer_root);
  _trust_store = caml_copy_string(trust_store);
  _transfer_root = caml_copy_string(transfer_root);
  caml_callback2_exn(*entry("init"), _trust_store, _transfer_root);
  CAMLdrop;
  leave_ocaml();
}

static long number(value _result) {
  return Is_exception_result(_result) ? -EIO : Long_val(_result);
}

long tsync_bridge_open(const char *ref, size_t length) {
  if (!atomic_load(&started))
    return -EIO;
  enter_ocaml();
  CAMLparam0();
  CAMLlocal1(_ref);
  _ref = caml_alloc_initialized_string(length, ref);
  long handle = number(caml_callback_exn(*entry("open"), _ref));
  CAMLdrop;
  leave_ocaml();
  return handle;
}

static long on_handle(const char *name, long handle) {
  if (!atomic_load(&started))
    return -EIO;
  enter_ocaml();
  long result = number(caml_callback_exn(*entry(name), Val_long(handle)));
  leave_ocaml();
  return result;
}

long tsync_bridge_size(long handle) { return on_handle("size", handle); }
long tsync_bridge_close(long handle) { return on_handle("close", handle); }

/* The destination is lent to OCaml for the call: the caller is blocked until
   the read has copied into it, and nothing keeps the array afterwards. */
long tsync_bridge_read(long handle, long offset, long length, char *dest) {
  if (!atomic_load(&started))
    return -EIO;
  enter_ocaml();
  CAMLparam0();
  CAMLlocal1(_buffer);
  intnat dims[1] = {length};
  _buffer = caml_ba_alloc(CAML_BA_UINT8 | CAML_BA_C_LAYOUT | CAML_BA_EXTERNAL,
                          1, dest, dims);
  long served = number(caml_callback3_exn(*entry("read"), Val_long(handle),
                                          Val_long(offset), _buffer));
  CAMLdrop;
  leave_ocaml();
  return served;
}
