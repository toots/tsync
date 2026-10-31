/* UTF-8 OCaml strings to and from the UTF-16 the Windows API takes. */

#ifndef TSYNC_CF_STRINGS_H
#define TSYNC_CF_STRINGS_H

#include <stdlib.h>
#include <windows.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

/* The caller frees the result. */
static inline wchar_t *utf16_of_utf8(const char *text, int length) {
  int units = MultiByteToWideChar(CP_UTF8, 0, text, length, NULL, 0);
  wchar_t *wide = malloc(((size_t)units + 1) * sizeof(wchar_t));
  if (wide == NULL)
    caml_raise_out_of_memory();
  MultiByteToWideChar(CP_UTF8, 0, text, length, wide, units);
  wide[units] = 0;
  return wide;
}

static inline wchar_t *utf16_of_value(value _text) {
  return utf16_of_utf8(String_val(_text), (int)caml_string_length(_text));
}

static inline value value_of_utf16_length(const wchar_t *wide, int units) {
  if (wide == NULL || units == 0)
    return caml_copy_string("");
  int bytes = WideCharToMultiByte(CP_UTF8, 0, wide, units, NULL, 0, NULL, NULL);
  value _text = caml_alloc_string(bytes);
  WideCharToMultiByte(CP_UTF8, 0, wide, units, (char *)Bytes_val(_text), bytes,
                      NULL, NULL);
  return _text;
}

static inline value value_of_utf16(const wchar_t *wide) {
  return value_of_utf16_length(wide, wide == NULL ? 0 : (int)wcslen(wide));
}

#endif
