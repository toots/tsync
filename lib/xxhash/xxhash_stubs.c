#include <xxhash.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/bigarray.h>
#include <caml/threads.h>

CAMLprim value caml_xxh3_64_with_seed(value _data, value _seed)
{
    CAMLparam2(_data, _seed);
    XXH64_hash_t hash = XXH3_64bits_withSeed(
        String_val(_data), caml_string_length(_data),
        (XXH64_hash_t)Long_val(_seed));
    CAMLreturn(caml_copy_int64(hash));
}

/* Bigarray data lives outside the OCaml heap and is never moved by the GC,
   so the runtime lock can be released while hashing: hashing threads run in
   parallel and the Lwt event loop keeps scheduling. */
CAMLprim value caml_xxh3_64_bigarray_with_seed(value _buffer, value _length,
                                               value _seed)
{
    CAMLparam3(_buffer, _length, _seed);
    void *data = Caml_ba_data_val(_buffer);
    size_t length = (size_t)Long_val(_length);
    XXH64_hash_t seed = (XXH64_hash_t)Long_val(_seed);
    caml_release_runtime_system();
    XXH64_hash_t hash = XXH3_64bits_withSeed(data, length, seed);
    caml_acquire_runtime_system();
    CAMLreturn(caml_copy_int64(hash));
}
