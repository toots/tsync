/* The bridge of android §5 as C calls, from any thread. Text is UTF-8 bytes
   with an explicit length; a text result is malloc'd and the caller frees it. */
#ifndef TSYNC_BRIDGE_H
#define TSYNC_BRIDGE_H

#include <stddef.h>

/* Once, on the thread that started the OCaml runtime, while it holds the
   runtime lock: the bridge answers from then on. */
void tsync_bridge_started(void);

/* name: check_config, boot, request, status or next_notice. NULL before the
   runtime started. check_config and request take the domain, a NUL, then the
   candidate or the request. */
char *tsync_bridge_text(const char *name, const char *arg, size_t arg_length,
                        size_t *length);

/* The host's trust store ("": the system's) and resource bounds (android §4.1
   items 2 and 7), 0 keeping the core's default; release_growth is in bytes. */
void tsync_bridge_init(const char *trust_store, const char *transfer_root,
                       long workers, long may_block, long release_growth);
long tsync_bridge_open(const char *domain, size_t domain_length,
                       const char *ref, size_t ref_length);
long tsync_bridge_size(long handle);
long tsync_bridge_read(long handle, long offset, long length, char *dest);
long tsync_bridge_close(long handle);

#endif
