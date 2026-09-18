/* Blocks a file owns before anything is written to it, so that a disk too full
 * for the file says so at once; the platforms differ only in which call names
 * the idea, hence one file with the branch inside.
 *
 * EOPNOTSUPP where nothing can reserve, which the caller gives a meaning to. */

#define _GNU_SOURCE

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/signals.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static int reserve(int fd, off_t size)
{
#if defined(__linux__)
    return fallocate(fd, 0, 0, size);
#elif defined(__APPLE__)
    fstore_t store = {F_ALLOCATECONTIG | F_ALLOCATEALL, F_PEOFPOSMODE, 0, size,
                      0};
    if (fcntl(fd, F_PREALLOCATE, &store) == -1) {
        store.fst_flags = F_ALLOCATEALL;
        if (fcntl(fd, F_PREALLOCATE, &store) == -1)
            return -1;
    }
    /* F_PREALLOCATE reserves without sizing. */
    return ftruncate(fd, size);
#else
    (void)fd;
    (void)size;
    errno = EOPNOTSUPP;
    return -1;
#endif
}

CAMLprim value caml_tsync_reserve(value _fd, value _size)
{
    CAMLparam2(_fd, _size);
    int fd = Int_val(_fd);
    off_t size = (off_t)Int64_val(_size);
    int result;

    caml_release_runtime_system();
    do {
        result = reserve(fd, size);
    } while (result == -1 && errno == EINTR);
    caml_acquire_runtime_system();

    if (result == -1)
        caml_uerror("reserve", Nothing);
    CAMLreturn(Val_unit);
}
