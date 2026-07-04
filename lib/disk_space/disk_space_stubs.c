#include <sys/statvfs.h>

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>

#include <stdlib.h>
#include <string.h>

CAMLprim value tsync_free_fraction(value _path) {
  CAMLparam1(_path);
  struct statvfs stats;
  char *path = strdup(String_val(_path));

  if (path == NULL) caml_raise_out_of_memory();

  caml_release_runtime_system();
  int result = statvfs(path, &stats);
  free(path);
  caml_acquire_runtime_system();

  if (result != 0) uerror("statvfs", _path);
  if (stats.f_blocks == 0) caml_failwith("statvfs: zero-sized filesystem");

  CAMLreturn(caml_copy_double((double)stats.f_bavail / (double)stats.f_blocks));
}
