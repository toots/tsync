/* Generic credentials of the user's Credential Manager (security-model
   §10.6), persisted for this machine only: the enterprise persistence roams. */

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <stdio.h>
#include <stdlib.h>
#include <windows.h>
#include <wincred.h>

static wchar_t *wide(value _text) {
  int units = MultiByteToWideChar(CP_UTF8, 0, String_val(_text),
                                  (int)caml_string_length(_text), NULL, 0);
  wchar_t *w = malloc(((size_t)units + 1) * sizeof(wchar_t));
  if (w == NULL)
    caml_raise_out_of_memory();
  MultiByteToWideChar(CP_UTF8, 0, String_val(_text), (int)caml_string_length(_text), w,
                      units);
  w[units] = 0;
  return w;
}

static value narrow(const wchar_t *w) {
  int bytes = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  value _text = caml_alloc_string(bytes > 0 ? bytes - 1 : 0);
  if (bytes > 1)
    WideCharToMultiByte(CP_UTF8, 0, w, -1, (char *)Bytes_val(_text), bytes - 1, NULL,
                        NULL);
  return _text;
}

static void fail_win32(const char *what, DWORD error) {
  char message[128];
  snprintf(message, sizeof message, "%s: Windows error %lu", what, (unsigned long)error);
  caml_failwith(message);
}

CAMLprim value tsync_cred_write(value _target, value _secret) {
  CAMLparam2(_target, _secret);
  wchar_t *target = wide(_target);
  mlsize_t length = caml_string_length(_secret);
  BYTE *blob = malloc(length == 0 ? 1 : length);
  if (blob == NULL)
    caml_raise_out_of_memory();
  memcpy(blob, String_val(_secret), length);
  CREDENTIALW cred = {0};
  cred.Type = CRED_TYPE_GENERIC;
  cred.TargetName = target;
  cred.CredentialBlobSize = (DWORD)length;
  cred.CredentialBlob = blob;
  cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
  cred.UserName = L"tsync";
  caml_release_runtime_system();
  BOOL ok = CredWriteW(&cred, 0);
  DWORD error = GetLastError();
  caml_acquire_runtime_system();
  SecureZeroMemory(blob, length);
  free(blob);
  free(target);
  if (!ok)
    fail_win32("writing the credential", error);
  CAMLreturn(Val_unit);
}

/* (target, secret) of every generic credential matching [_filter], a target
   with one trailing '*'. */
CAMLprim value tsync_cred_list(value _filter) {
  CAMLparam1(_filter);
  CAMLlocal4(_list, _cell, _pair, _field);
  wchar_t *filter = wide(_filter);
  DWORD count = 0;
  PCREDENTIALW *creds = NULL;
  caml_release_runtime_system();
  BOOL ok = CredEnumerateW(filter, 0, &count, &creds);
  DWORD error = GetLastError();
  caml_acquire_runtime_system();
  free(filter);
  if (!ok) {
    if (error == ERROR_NOT_FOUND)
      CAMLreturn(Val_emptylist);
    fail_win32("listing the credentials", error);
  }
  _list = Val_emptylist;
  for (DWORD i = 0; i < count; i++) {
    if (creds[i]->Type != CRED_TYPE_GENERIC)
      continue;
    _pair = caml_alloc_tuple(2);
    _field = narrow(creds[i]->TargetName);
    Store_field(_pair, 0, _field);
    _field = caml_alloc_initialized_string(creds[i]->CredentialBlobSize,
                                           (const char *)creds[i]->CredentialBlob);
    Store_field(_pair, 1, _field);
    _cell = caml_alloc_small(2, 0);
    Field(_cell, 0) = _pair;
    Field(_cell, 1) = _list;
    _list = _cell;
  }
  CredFree(creds);
  CAMLreturn(_list);
}

CAMLprim value tsync_cred_delete(value _target) {
  CAMLparam1(_target);
  wchar_t *target = wide(_target);
  caml_release_runtime_system();
  BOOL ok = CredDeleteW(target, CRED_TYPE_GENERIC, 0);
  DWORD error = GetLastError();
  caml_acquire_runtime_system();
  free(target);
  if (!ok && error != ERROR_NOT_FOUND)
    fail_win32("deleting the credential", error);
  CAMLreturn(Val_unit);
}
