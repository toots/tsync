#include <xxhash.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

CAMLprim value caml_xxh3_64_with_seed(value _data, value _seed)
{
    CAMLparam2(_data, _seed);
    XXH64_hash_t hash = XXH3_64bits_withSeed(
        String_val(_data), caml_string_length(_data),
        (XXH64_hash_t)Long_val(_seed));
    CAMLreturn(caml_copy_int64(hash));
}
