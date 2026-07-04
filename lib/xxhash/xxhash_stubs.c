#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xxhash.h>

#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

CAMLprim value caml_xxh3_64_with_seed(value _data, value _seed)
{
    CAMLparam2(_data, _seed);
    XXH64_hash_t hash = XXH3_64bits_withSeed(
        String_val(_data), caml_string_length(_data),
        (XXH64_hash_t)Long_val(_seed));
    CAMLreturn(caml_copy_int64(hash));
}

/* Opaque hashing state: the file to hash plus a cancel flag. It is allocated off
   the OCaml heap (the custom block only holds a pointer) so its atomic can be
   read from a worker domain with the runtime lock released, even if the GC moves
   the wrapping block. The event loop flips [cancel] via caml_hash_state_cancel;
   the hashing loop polls it between chunks. */
struct hash_state {
    char *path;
    atomic_int cancel;
};

#define Hash_state_val(v) (*((struct hash_state **)Data_custom_val(v)))

static void hash_state_finalize(value v)
{
    struct hash_state *s = Hash_state_val(v);
    free(s->path);
    free(s);
}

static struct custom_operations hash_state_ops = {
    "tsync.hash_state",
    hash_state_finalize,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default};

CAMLprim value caml_hash_state_create(value _path)
{
    CAMLparam1(_path);
    CAMLlocal1(v);
    struct hash_state *s = malloc(sizeof(struct hash_state));
    if (s == NULL)
        caml_raise_out_of_memory();
    s->path = strdup(String_val(_path));
    if (s->path == NULL) {
        free(s);
        caml_raise_out_of_memory();
    }
    atomic_init(&s->cancel, 0);
    v = caml_alloc_custom(&hash_state_ops, sizeof(struct hash_state *), 0, 1);
    Hash_state_val(v) = s;
    CAMLreturn(v);
}

CAMLprim value caml_hash_state_cancel(value v)
{
    atomic_store(&Hash_state_val(v)->cancel, 1);
    return Val_unit;
}

CAMLprim value caml_hash_state_reset(value v)
{
    atomic_store(&Hash_state_val(v)->cancel, 0);
    return Val_unit;
}

CAMLprim value caml_hash_state_is_cancelled(value v)
{
    return Val_bool(atomic_load(&Hash_state_val(v)->cancel));
}

/* Open + mmap the state's file, then hash every chunk (seeds 0 and 1) with the
   runtime lock released, polling the state's cancel flag between chunks. Returns
   [Some (file_size, hashes)] where hashes is an int64 array of length
   2*num_chunks (element 2*i is chunk i's seed-0 hash, 2*i+1 the seed-1 hash), or
   [None] if the flag was set partway through or the file could not be opened.
   OCaml allocation happens only with the lock held. */
CAMLprim value caml_hash_file_chunks(value _state, value _chunk_size)
{
    CAMLparam2(_state, _chunk_size);
    CAMLlocal3(result, pair, arr);
    struct hash_state *s = Hash_state_val(_state);
    size_t chunk_size = (size_t)Long_val(_chunk_size);

    int fd = open(s->path, O_RDONLY);
    if (fd < 0)
        CAMLreturn(Val_int(0)); /* None: file vanished — drop the upload */
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        CAMLreturn(Val_int(0));
    }
    size_t length = (size_t)st.st_size;
    size_t num_chunks =
        (length == 0) ? 1 : (length + chunk_size - 1) / chunk_size;

    const char *data = NULL;
    if (length > 0) {
        data = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0);
        if (data == MAP_FAILED) {
            close(fd);
            caml_raise_out_of_memory();
        }
    }
    close(fd); /* the mapping stays valid after close */

    XXH64_hash_t *scratch = malloc(sizeof(XXH64_hash_t) * 2 * num_chunks);
    if (scratch == NULL) {
        if (data)
            munmap((void *)data, length);
        caml_raise_out_of_memory();
    }

    int cancelled = 0;
    caml_release_runtime_system();
    for (size_t i = 0; i < num_chunks; i++) {
        if (atomic_load(&s->cancel)) {
            cancelled = 1;
            break;
        }
        size_t off = i * chunk_size;
        size_t len = (off + chunk_size <= length) ? chunk_size : (length - off);
        scratch[2 * i]     = XXH3_64bits_withSeed(data + off, len, 0);
        scratch[2 * i + 1] = XXH3_64bits_withSeed(data + off, len, 1);
    }
    caml_acquire_runtime_system();

    if (data)
        munmap((void *)data, length);

    if (cancelled) {
        free(scratch);
        CAMLreturn(Val_int(0)); /* None */
    }

    arr = caml_alloc(2 * num_chunks, 0);
    for (size_t i = 0; i < 2 * num_chunks; i++)
        Store_field(arr, i, caml_copy_int64((int64_t)scratch[i]));
    free(scratch);

    pair = caml_alloc(2, 0);
    Store_field(pair, 0, Val_long(length));
    Store_field(pair, 1, arr);
    result = caml_alloc(1, 0); /* Some pair */
    Store_field(result, 0, pair);
    CAMLreturn(result);
}
