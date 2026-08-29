/* Foreign threads calling the domain, which is what the Android app is.

   The registration rules are the risk: a thread that calls OCaml without
   registering segfaults at its first blocking section, and one that dies still
   registered leaves the collector walking a C stack that is gone. Neither shows
   up on the thread that starts the runtime, so a test that drives the entry
   points from OCaml alone proves nothing about them. */

#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/bigarray.h>
#include <caml/alloc.h>
#include <caml/threads.h>
#include <pthread.h>
#include <string.h>

void tsync_enter_ocaml(void);
void tsync_leave_ocaml(void);

struct worker {
    pthread_t thread;
    int handle;
    int reads;
    long length;
    const char *expected;
    int mismatches;
};

/* One range per read, walking the file, checked against the bytes the caller
   knows are there. */
static void *run(void *raw) {
    struct worker *w = raw;
    const value *read = NULL;
    long window = 64;

    for (int i = 0; i < w->reads; i++) {
        long offset = (long)((i * window) % w->length);
        long want = w->length - offset < window ? w->length - offset : window;

        tsync_enter_ocaml();
        {
            CAMLparam0();
            CAMLlocal2(buffer, served);
            if (!read) read = caml_named_value("tsync_jni_read");
            intnat dim = want;
            buffer = caml_ba_alloc(
                CAML_BA_UINT8 | CAML_BA_C_LAYOUT | CAML_BA_MANAGED, 1, NULL, &dim);
            served = caml_callback3(*read, Val_int(w->handle),
                                    caml_copy_int64(offset), buffer);
            long n = Long_val(served);
            if (n != want ||
                memcmp(Caml_ba_data_val(buffer), w->expected + offset, n) != 0)
                w->mismatches++;
            CAMLdrop;
        }
        tsync_leave_ocaml();
    }
    return NULL;
}

/* Threads are joined, so every one of them unregisters through the key's
   destructor while the runtime is still up -- the ordering a pool that reaps
   its threads would also take. */
CAMLprim value tsync_stress(value _threads, value _handle, value _reads,
                            value _expected) {
    CAMLparam4(_threads, _handle, _reads, _expected);
    int count = Int_val(_threads);
    long length = caml_string_length(_expected);
    char *expected = malloc(length);
    memcpy(expected, String_val(_expected), length);

    struct worker *workers = calloc(count, sizeof *workers);
    for (int i = 0; i < count; i++) {
        workers[i].handle = Int_val(_handle);
        workers[i].reads = Int_val(_reads);
        workers[i].length = length;
        workers[i].expected = expected;
    }

    caml_release_runtime_system();
    for (int i = 0; i < count; i++)
        pthread_create(&workers[i].thread, NULL, run, &workers[i]);
    for (int i = 0; i < count; i++) pthread_join(workers[i].thread, NULL);
    caml_acquire_runtime_system();

    int mismatches = 0;
    for (int i = 0; i < count; i++) mismatches += workers[i].mismatches;
    free(workers);
    free(expected);
    CAMLreturn(Val_int(mismatches));
}
