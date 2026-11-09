/* What an iOS host calls besides the bridge: start the core once per process,
   from any thread, then use tsync_bridge.h. */
#ifndef TSYNC_IOS_H
#define TSYNC_IOS_H

#include "tsync_bridge.h"

/* Sets the environment the core reads (ios.md §3.2, §4), starts the runtime
   and passes the host's bounds; 0 keeps the core's default. Later calls do
   nothing. */
void tsync_ios_start(const char *home, const char *config_file,
                     const char *transfer_root, long minor_heap_words,
                     long workers, long may_block, long release_growth);

#endif
