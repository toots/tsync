#include <xxhash.h>

#include <caml/alloc.h>
#include <caml/custom.h>
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

static void xxh3_state_finalize(value _state)
{
    XXH3_freeState(*((XXH3_state_t **)Data_custom_val(_state)));
}

static struct custom_operations xxh3_state_ops = {
    "xxh3_state",
    xxh3_state_finalize,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default
};

CAMLprim value caml_xxh3_state_create(value _seed)
{
    CAMLparam1(_seed);
    CAMLlocal1(_state);
    XXH3_state_t *state = XXH3_createState();
    XXH3_64bits_reset_withSeed(state, (XXH64_hash_t)Long_val(_seed));
    _state = caml_alloc_custom(&xxh3_state_ops, sizeof(XXH3_state_t *), 0, 1);
    *((XXH3_state_t **)Data_custom_val(_state)) = state;
    CAMLreturn(_state);
}

CAMLprim value caml_xxh3_state_update(value _state, value _data)
{
    CAMLparam2(_state, _data);
    XXH3_64bits_update(
        *((XXH3_state_t **)Data_custom_val(_state)),
        String_val(_data), caml_string_length(_data));
    CAMLreturn(Val_unit);
}

CAMLprim value caml_xxh3_state_digest(value _state)
{
    CAMLparam1(_state);
    XXH64_hash_t hash =
        XXH3_64bits_digest(*((XXH3_state_t **)Data_custom_val(_state)));
    CAMLreturn(caml_copy_int64(hash));
}
