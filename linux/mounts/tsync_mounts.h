/* The host side of libtsync_mounts.so (spec frontends/linux-desktop.md §3.4).
   Compiled into the host, against the OCaml runtime headers. */
#ifndef TSYNC_MOUNTS_H
#define TSYNC_MOUNTS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One pair, copied out of the library before this is called. */
typedef void (*tsync_mount_emit)(void *context, const char *mount_point,
                                 size_t mount_point_length, const char *socket,
                                 size_t socket_length);

/* Asks the library for the mounted domains. The first call starts the
   library's runtime; every call must come from that same thread. Returns the
   number of pairs, or -1 when the library has no entry point. */
int tsync_mounts_query(tsync_mount_emit emit, void *context);

#ifdef __cplusplus
}
#endif

#endif
