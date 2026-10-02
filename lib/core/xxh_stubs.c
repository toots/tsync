#define XXH_INLINE_ALL
#include "xxhash.h"
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <string.h>

CAMLprim value tsync_xxh3_string(value s, value off, value len, value seed) {
  return caml_copy_int64(XXH3_64bits_withSeed(String_val(s) + Long_val(off), Long_val(len), (XXH64_hash_t)Int64_val(seed)));
}

/* A bigstring may be a mapping of a slow disk: hashing it can fault for a long
   time, so the runtime is released while it runs. */
CAMLprim value tsync_xxh3_bigstring(value b, value off, value len, value seed) {
  CAMLparam4(b, off, len, seed);
  const char *data = (char *)Caml_ba_data_val(b) + Long_val(off);
  size_t n = Long_val(len);
  XXH64_hash_t s = (XXH64_hash_t)Int64_val(seed);
  caml_release_runtime_system();
  XXH64_hash_t h = XXH3_64bits_withSeed(data, n, s);
  caml_acquire_runtime_system();
  CAMLreturn(caml_copy_int64(h));
}

#define State_val(v) (*((XXH3_state_t **)Data_custom_val(v)))

static void state_finalize(value v) { XXH3_freeState(State_val(v)); }

static struct custom_operations state_ops = {
  "tsync.xxh3_state", state_finalize, custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default};

CAMLprim value tsync_xxh3_create(value seed) {
  CAMLparam1(seed);
  CAMLlocal1(v);
  XXH3_state_t *st = XXH3_createState();
  XXH3_64bits_reset_withSeed(st, (XXH64_hash_t)Int64_val(seed));
  v = caml_alloc_custom(&state_ops, sizeof(XXH3_state_t *), 0, 1);
  State_val(v) = st;
  CAMLreturn(v);
}

CAMLprim value tsync_xxh3_update_string(value st, value s, value off, value len) {
  XXH3_64bits_update(State_val(st), String_val(s) + Long_val(off), Long_val(len));
  return Val_unit;
}

CAMLprim value tsync_xxh3_update_bigstring(value st, value b, value off, value len) {
  CAMLparam4(st, b, off, len);
  XXH3_state_t *state = State_val(st);
  const char *data = (char *)Caml_ba_data_val(b) + Long_val(off);
  size_t n = Long_val(len);
  caml_release_runtime_system();
  XXH3_64bits_update(state, data, n);
  caml_acquire_runtime_system();
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_xxh3_digest(value st) { return caml_copy_int64(XXH3_64bits_digest(State_val(st))); }
