/* Positioned reads and writes into off-heap bytes, which Lwt offers for [Bytes]
 * only: several ranges of one file move concurrently through one descriptor,
 * and carrying the offset in the call is what keeps them off a shared seek
 * position.
 *
 * Blocking, as every read Lwt performs on a regular file is: such a descriptor
 * is always ready, so there is no job to run. */

#define _XOPEN_SOURCE 600

#include <caml/bigarray.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>

#include <errno.h>
#include <unistd.h>

static value positioned(value _fd, value _buf, value _file_offset, value _pos,
                        value _len, int writing)
{
    CAMLparam5(_fd, _buf, _file_offset, _pos, _len);
    char *base = (char *)Caml_ba_data_val(_buf);
    size_t len = (size_t)Long_val(_len);
    off_t file_offset = (off_t)Long_val(_file_offset);
    char *at = base + Long_val(_pos);
    ssize_t moved;

    /* The bigarray's data never moves, so the pointer stays valid with the
       runtime lock released and a page fault on a mapping cannot deadlock. */
    caml_release_runtime_system();
    do {
        moved = writing ? pwrite(Int_val(_fd), at, len, file_offset)
                        : pread(Int_val(_fd), at, len, file_offset);
    } while (moved == -1 && errno == EINTR);
    caml_acquire_runtime_system();

    if (moved == -1)
        caml_uerror(writing ? "pwrite" : "pread", Nothing);
    CAMLreturn(Val_long(moved));
}

CAMLprim value caml_tsync_pread(value _fd, value _buf, value _file_offset,
                                value _pos, value _len)
{
    return positioned(_fd, _buf, _file_offset, _pos, _len, 0);
}

CAMLprim value caml_tsync_pread_bytecode(value *argv, int argn)
{
    return caml_tsync_pread(argv[0], argv[1], argv[2], argv[3], argv[4]);
}

CAMLprim value caml_tsync_pwrite(value _fd, value _buf, value _file_offset,
                                 value _pos, value _len)
{
    return positioned(_fd, _buf, _file_offset, _pos, _len, 1);
}

CAMLprim value caml_tsync_pwrite_bytecode(value *argv, int argn)
{
    return caml_tsync_pwrite(argv[0], argv[1], argv[2], argv[3], argv[4]);
}
