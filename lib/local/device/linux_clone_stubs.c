/* A copy-on-write clone: the filesystem duplicates references to the source's
 * extents rather than its bytes, so it costs no space and no time proportional
 * to the file.
 *
 * ponytail: the errno is not reported, only whether it worked, because every
 * failure means the same thing to the caller. */

#include <caml/memory.h>
#include <caml/mlvalues.h>

#include <sys/ioctl.h>

#include <linux/fs.h>

#ifdef FICLONE

/* Fast enough not to release the runtime lock: it rewrites extent references
 * and moves no data. */
CAMLprim value tsync_ficlone(value _dst_fd, value _src_fd) {
  CAMLparam2(_dst_fd, _src_fd);
  CAMLreturn(Val_bool(ioctl(Int_val(_dst_fd), FICLONE, Int_val(_src_fd)) == 0));
}

#else

/* Kernel headers too old to name the ioctl, which the caller already handles as
 * a filesystem that will not clone. */
CAMLprim value tsync_ficlone(value _dst_fd, value _src_fd) {
  CAMLparam2(_dst_fd, _src_fd);
  CAMLreturn(Val_false);
}

#endif
