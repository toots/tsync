#include <stdlib.h>
#include <xxhash.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/bigarray.h>
#include <caml/fail.h>
#include <caml/threads.h>

CAMLprim value caml_xxh3_64_with_seed(value _data, value _seed)
{
    CAMLparam2(_data, _seed);
    XXH64_hash_t hash = XXH3_64bits_withSeed(
        String_val(_data), caml_string_length(_data),
        (XXH64_hash_t)Long_val(_seed));
    CAMLreturn(caml_copy_int64(hash));
}

/* Hash every chunk of a whole-file bigarray in a single runtime-lock window.
   Bigarray data lives outside the OCaml heap and is never moved by the GC, so
   the lock can be released for the entire loop — one release/acquire per file
   instead of per chunk. num_chunks mirrors remote.ml's max(1, ceil(len/chunk)):
   a 0-byte file still yields one (empty) chunk. Returns an int64 array of length
   2*num_chunks: for chunk i, element 2*i is the seed-0 hash and 2*i+1 the seed-1
   hash. Hashing fills a plain C scratch array with the lock RELEASED; OCaml
   allocation of the result happens only after it is re-ACQUIRED. */
CAMLprim value caml_xxh3_64_chunks_bigarray(value _buffer, value _length,
                                            value _chunk_size)
{
    CAMLparam3(_buffer, _length, _chunk_size);
    CAMLlocal1(result);
    const char *data = (const char *)Caml_ba_data_val(_buffer);
    size_t length = (size_t)Long_val(_length);
    size_t chunk_size = (size_t)Long_val(_chunk_size);
    size_t num_chunks =
        (length == 0) ? 1 : (length + chunk_size - 1) / chunk_size;

    XXH64_hash_t *scratch = malloc(sizeof(XXH64_hash_t) * 2 * num_chunks);
    if (scratch == NULL)
        caml_failwith("xxh3_64_chunks_bigarray: out of memory");

    caml_release_runtime_system();
    for (size_t i = 0; i < num_chunks; i++) {
        size_t off = i * chunk_size;
        size_t len = (off + chunk_size <= length) ? chunk_size : (length - off);
        scratch[2 * i]     = XXH3_64bits_withSeed(data + off, len, 0);
        scratch[2 * i + 1] = XXH3_64bits_withSeed(data + off, len, 1);
    }
    caml_acquire_runtime_system();

    result = caml_alloc(2 * num_chunks, 0);
    for (size_t i = 0; i < 2 * num_chunks; i++)
        Store_field(result, i, caml_copy_int64((int64_t)scratch[i]));

    free(scratch);
    CAMLreturn(result);
}
