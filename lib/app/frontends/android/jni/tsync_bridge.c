/* What the domain needs from the host process it is linked into: a way for the
   platform's own threads to call OCaml, and a log the host can read.

   Modelled on the fuse3 binding's Fuse_util.c, which registers libfuse's worker
   threads the same way. Free of JNI so a host test can drive it from plain
   pthreads, which is where the registration rules are worth proving. */

#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef __ANDROID__
#include <android/log.h>

static int android_priority(int level) {
    switch (level) {
        case 0: return ANDROID_LOG_DEBUG;
        case 1: return ANDROID_LOG_INFO;
        case 2: return ANDROID_LOG_WARN;
        default: return ANDROID_LOG_ERROR;
    }
}
#endif

/* [level] is Log.level as a rank: 0 debug, 1 info, 2 warn, 3 error. */
CAMLprim value tsync_log_write(value _level, value _message) {
    CAMLparam2(_level, _message);
    const char *message = String_val(_message);
#ifdef __ANDROID__
    __android_log_write(android_priority(Int_val(_level)), "tsync", message);
#else
    fprintf(stderr, "%s\n", message);
    fflush(stderr);
#endif
    CAMLreturn(Val_unit);
}

/* Whether this thread was registered here, and so whether it owes an
   unregister. The thread that started the runtime is OCaml's own and must not
   be handed to caml_c_thread_unregister. */
#define TSYNC_THREAD_FOREIGN ((void *)1)
#define TSYNC_THREAD_RUNTIME ((void *)2)

static pthread_key_t thread_key;
static pthread_once_t thread_key_once = PTHREAD_ONCE_INIT;

/* A registered thread that dies still appears in the domain's thread list, and
   caml_thread_scan_roots walks the C stack it saved -- memory that is gone once
   the thread is. */
static void leave_for_good(void *state) {
    if (state == TSYNC_THREAD_FOREIGN) caml_c_thread_unregister();
}

static void make_thread_key(void) {
    pthread_key_create(&thread_key, leave_for_good);
}

/* Call once, on the thread that started the runtime and so holds the lock
   already: without this the first call from it would try to register a thread
   the runtime knows, read the 0 that means "already", and abort. */
void tsync_bridge_init(void) {
    pthread_once(&thread_key_once, make_thread_key);
    pthread_setspecific(thread_key, TSYNC_THREAD_RUNTIME);
}

/* Returns holding the runtime lock. Registration leaves a thread without it --
   caml_c_thread_register ends in a blocking section -- so the acquire is not
   optional, and neither is the abort: an unregistered thread has no Caml_state
   and segfaults at the first blocking section rather than raising. */
void tsync_enter_ocaml(void) {
    pthread_once(&thread_key_once, make_thread_key);
    if (pthread_getspecific(thread_key) == NULL) {
        if (caml_c_thread_register() == 0) {
            fprintf(stderr, "tsync: caml_c_thread_register failed\n");
            fflush(stderr);
            abort();
        }
        pthread_setspecific(thread_key, TSYNC_THREAD_FOREIGN);
    }
    caml_acquire_runtime_system();
}

void tsync_leave_ocaml(void) { caml_release_runtime_system(); }
