/* Monocypher is compiled into this unit: dune builds stubs only from this
   directory. */
#include "monocypher.c"
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <stdlib.h>
#include <string.h>

/* XChaCha20-Poly1305: returns ciphertext followed by the 16-byte tag. */
CAMLprim value tsync_vault_seal(value _key, value _nonce, value _ad, value _plaintext) {
  CAMLparam4(_key, _nonce, _ad, _plaintext);
  CAMLlocal1(_sealed);
  size_t plaintext_size = caml_string_length(_plaintext);
  _sealed = caml_alloc_string(plaintext_size + 16);
  uint8_t *sealed = (uint8_t *)Bytes_val(_sealed);
  crypto_aead_lock(sealed, sealed + plaintext_size, (const uint8_t *)String_val(_key),
                   (const uint8_t *)String_val(_nonce), (const uint8_t *)String_val(_ad),
                   caml_string_length(_ad), (const uint8_t *)String_val(_plaintext),
                   plaintext_size);
  CAMLreturn(_sealed);
}

/* Returns [Some plaintext], or [None] when authentication fails. */
CAMLprim value tsync_vault_open(value _key, value _nonce, value _ad, value _sealed) {
  CAMLparam4(_key, _nonce, _ad, _sealed);
  CAMLlocal2(_plaintext, _result);
  size_t sealed_size = caml_string_length(_sealed);
  if (sealed_size < 16) CAMLreturn(Val_none);
  size_t plaintext_size = sealed_size - 16;
  _plaintext = caml_alloc_string(plaintext_size);
  const uint8_t *sealed = (const uint8_t *)String_val(_sealed);
  int failed = crypto_aead_unlock((uint8_t *)Bytes_val(_plaintext), sealed + plaintext_size,
                                  (const uint8_t *)String_val(_key),
                                  (const uint8_t *)String_val(_nonce),
                                  (const uint8_t *)String_val(_ad), caml_string_length(_ad),
                                  sealed, plaintext_size);
  if (failed) CAMLreturn(Val_none);
  _result = caml_alloc_some(_plaintext);
  CAMLreturn(_result);
}

/* Argon2id version 0x13 with a 32-byte output. An empty [_secret] or [_ad]
   means none. The work area is the whole memory cost, so the runtime is
   released while it runs. */
CAMLprim value tsync_vault_argon2id_native(value _password, value _salt, value _secret,
                                           value _ad, value _mem_kib, value _iterations,
                                           value _lanes) {
  CAMLparam5(_password, _salt, _secret, _ad, _mem_kib);
  CAMLxparam2(_iterations, _lanes);
  CAMLlocal1(_hash);
  uint32_t mem_kib = (uint32_t)Long_val(_mem_kib);
  void *work_area = malloc((size_t)mem_kib * 1024);
  if (work_area == NULL) caml_raise_out_of_memory();
  size_t password_size = caml_string_length(_password);
  size_t salt_size = caml_string_length(_salt);
  size_t secret_size = caml_string_length(_secret);
  size_t ad_size = caml_string_length(_ad);
  /* Copies, since the inputs may move while the runtime is released. */
  uint8_t *inputs = malloc(password_size + salt_size + secret_size + ad_size + 1);
  if (inputs == NULL) {
    free(work_area);
    caml_raise_out_of_memory();
  }
  uint8_t *password = inputs;
  uint8_t *salt = password + password_size;
  uint8_t *secret = salt + salt_size;
  uint8_t *ad = secret + secret_size;
  memcpy(password, String_val(_password), password_size);
  memcpy(salt, String_val(_salt), salt_size);
  memcpy(secret, String_val(_secret), secret_size);
  memcpy(ad, String_val(_ad), ad_size);
  crypto_argon2_config config = {CRYPTO_ARGON2_ID, mem_kib, (uint32_t)Long_val(_iterations),
                                 (uint32_t)Long_val(_lanes)};
  crypto_argon2_inputs argon_inputs = {password, salt, (uint32_t)password_size,
                                       (uint32_t)salt_size};
  crypto_argon2_extras extras = {secret_size ? secret : NULL, ad_size ? ad : NULL,
                                 (uint32_t)secret_size, (uint32_t)ad_size};
  uint8_t hash[32];
  caml_release_runtime_system();
  crypto_argon2(hash, sizeof hash, work_area, config, argon_inputs, extras);
  caml_acquire_runtime_system();
  crypto_wipe(inputs, password_size + salt_size + secret_size + ad_size);
  free(inputs);
  free(work_area);
  _hash = caml_alloc_initialized_string(sizeof hash, (const char *)hash);
  crypto_wipe(hash, sizeof hash);
  CAMLreturn(_hash);
}

CAMLprim value tsync_vault_argon2id_bytecode(value *argv, int argn) {
  (void)argn;
  return tsync_vault_argon2id_native(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5],
                                     argv[6]);
}
