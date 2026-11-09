/* What an iOS host calls besides the bridge: start the core once per process,
   from any thread, then use tsync_bridge.h. */
#ifndef TSYNC_IOS_H
#define TSYNC_IOS_H

#include "tsync_bridge.h"

/* Sets HOME, starts the runtime and passes the host's bounds (0: the core's
   default); later calls do nothing. The minor heap is set by OCAMLRUNPARAM in
   the environment before the first call. */
void tsync_ios_start(const char *home, const char *transfer_root, long workers,
                     long may_block, long release_growth);

#endif
