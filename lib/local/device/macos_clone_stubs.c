/* A copy-on-write clone: the filesystem duplicates references to the source's
 * blocks rather than the blocks, so it costs no space and no time proportional
 * to the file.
 *
 * Unlike Linux's FICLONE this creates the destination itself, which is why it
 * takes paths where the other takes descriptors. */

#include <caml/memory.h>
#include <caml/mlvalues.h>

#include <sys/clonefile.h>

/* Fast enough not to release the runtime lock: it copies metadata and shares
 * the blocks. */
CAMLprim value tsync_clonefile(value _src, value _dst) {
  CAMLparam2(_src, _dst);
  CAMLreturn(Val_bool(clonefile(String_val(_src), String_val(_dst), 0) == 0));
}
