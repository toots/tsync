/* Free and total bytes of the filesystem holding a path.
 *
 * The OCaml stdlib has no statvfs binding, and POSIX means one implementation
 * serves every platform tsync targets.
 *
 * f_frsize is the fragment size the block counts are expressed in; f_bsize is
 * only a hint about efficient I/O and is the wrong multiplier. f_bavail is what
 * an unprivileged writer can actually use, unlike f_bfree, which includes the
 * reserved margin. Both are reported: a writer sizing a request wants f_bavail,
 * while df derives its used column as f_blocks - f_bfree and overstates usage by
 * the reserved margin if handed f_bavail instead.
 *
 * ponytail: Windows has no statvfs (it would be GetDiskFreeSpaceEx) and tsync has
 * no Windows target, so there it fails and the caller reports no capacity rather
 * than the build breaking. Implement that branch if a Windows port happens. */

#include <stdlib.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>

#include <errno.h>
#include <string.h>

#ifndef _WIN32
#include <sys/statvfs.h>
#endif

CAMLprim value tsync_statvfs(value _path) {
  CAMLparam1(_path);
#ifdef _WIN32
  caml_failwith("statvfs: unsupported on this platform");
  CAMLreturn(Val_unit);
#else
  CAMLlocal1(result);
  struct statvfs buf;
  char path[4096];
  size_t len = caml_string_length(_path);

  if (len >= sizeof(path))
    caml_failwith("statvfs: path too long");

  /* Copy out before releasing the runtime lock: the OCaml heap may move. */
  memcpy(path, String_val(_path), len);
  path[len] = '\0';

  caml_release_runtime_system();
  int rc = statvfs(path, &buf);
  int saved_errno = errno;
  caml_acquire_runtime_system();

  if (rc != 0) {
    errno = saved_errno;
    caml_uerror("statvfs", _path);
  }

  /* (available, free, total) in bytes. */
  result = caml_alloc_tuple(3);
  Store_field(result, 0,
              caml_copy_int64((int64_t)buf.f_bavail * (int64_t)buf.f_frsize));
  Store_field(result, 1,
              caml_copy_int64((int64_t)buf.f_bfree * (int64_t)buf.f_frsize));
  Store_field(result, 2,
              caml_copy_int64((int64_t)buf.f_blocks * (int64_t)buf.f_frsize));
  CAMLreturn(result);
#endif
}

/* The machine's one-minute load average, or a negative value where the
   platform has no way to say. Beside statvfs because both answer for the box
   a process is on rather than for the process. */
CAMLprim value tsync_loadavg(value unit) {
  CAMLparam1(unit);
#if defined(__linux__) || defined(__APPLE__)
  double load[1];
  if (getloadavg(load, 1) == 1) CAMLreturn(caml_copy_double(load[0]));
#endif
  CAMLreturn(caml_copy_double(-1.0));
}
