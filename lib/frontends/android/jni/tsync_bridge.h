/* The bridge of android §5 as C calls, from any thread. Text is UTF-8 bytes
   with an explicit length; a text result is malloc'd and the caller frees it. */
#ifndef TSYNC_BRIDGE_H
#define TSYNC_BRIDGE_H

#include <stddef.h>

/* Once, on the thread that started the OCaml runtime, while it holds the
   runtime lock: the bridge answers from then on. */
void tsync_bridge_started(void);

/* name: check_config, boot, request, status or next_notice. NULL before the
   runtime started. */
char *tsync_bridge_text(const char *name, const char *arg, size_t arg_length,
                        size_t *length);

void tsync_bridge_init(const char *trust_store, const char *transfer_root);
long tsync_bridge_open(const char *ref, size_t length);
long tsync_bridge_size(long handle);
long tsync_bridge_read(long handle, long offset, long length, char *dest);
long tsync_bridge_close(long handle);

#endif
