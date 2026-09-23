/* Seconds on a clock that only moves forward.
 *
 * The OCaml stdlib offers wall time alone, and wall time steps: NTP sets it
 * back and forth by tens of milliseconds, which is the size of the intervals
 * a rate controller reads off a clock. CLOCK_MONOTONIC is what POSIX gives for
 * an interval, and one implementation serves every platform tsync targets:
 * Linux, macOS from 10.12, and Android's bionic all have it.
 *
 * The origin means nothing, so the value is only ever subtracted from another
 * read of the same clock. Read without releasing the runtime lock: it is a
 * vDSO call, cheaper than the release would be.
 *
 * ponytail: Windows has no clock_gettime (it would be QueryPerformanceCounter)
 * and tsync has no Windows target, so there it fails rather than the build
 * breaking. Implement that branch if a Windows port happens. */

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#ifndef _WIN32
#include <time.h>
#endif

CAMLprim value tsync_monotonic_now(value unit) {
  CAMLparam1(unit);
#ifdef _WIN32
  caml_failwith("monotonic_now: unsupported on this platform");
  CAMLreturn(Val_unit);
#else
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    caml_failwith("monotonic_now: clock_gettime failed");
  CAMLreturn(caml_copy_double((double)ts.tv_sec + (double)ts.tv_nsec * 1e-9));
#endif
}
