/* This process's open-file limit.
 *
 * The OCaml stdlib has no getrlimit/setrlimit binding, and both are POSIX, so
 * one implementation serves every platform tsync targets.
 *
 * launchd starts the macOS daemon with a soft limit of 256 against an unlimited
 * hard limit, low enough that a burst of concurrent work fails accept(2) with
 * EMFILE. A process may raise its own soft limit up to the hard one without
 * privilege, so the daemon needs no special launch.
 *
 * The real ceiling is discovered, not asked for: macOS caps a process at
 * kern.maxfilesperproc and Linux at /proc/sys/fs/nr_open, and on macOS the hard
 * limit is often RLIM_INFINITY, above which setrlimit simply fails. So ask for
 * the target and halve it until the kernel accepts one — two or three tries at
 * most, once, at start-up.
 *
 * ponytail: no Windows branch. There the limit is per-CRT rather than per
 * process (_setmaxstdio) and tsync has no Windows target, so this reports the
 * current limit unchanged and the caller carries on. Implement it if a port
 * happens. */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

#ifndef _WIN32
#include <sys/resource.h>
#include <sys/time.h>
#endif

/* The soft limit in force, or -1 if it cannot be read. */
CAMLprim value tsync_nofile_current(value unit) {
  CAMLparam1(unit);
#ifdef _WIN32
  CAMLreturn(Val_long(-1));
#else
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) != 0)
    CAMLreturn(Val_long(-1));
  if (rl.rlim_cur == RLIM_INFINITY)
    CAMLreturn(Val_long(Max_long));
  CAMLreturn(Val_long((long)rl.rlim_cur));
#endif
}

/* Raise the soft limit toward [target], returning what is now in force. Never
 * lowers it. */
CAMLprim value tsync_nofile_raise(value _target) {
  CAMLparam1(_target);
#ifdef _WIN32
  CAMLreturn(Val_long(-1));
#else
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) != 0)
    CAMLreturn(Val_long(-1));

  rlim_t current = rl.rlim_cur;
  rlim_t want = (rlim_t)Long_val(_target);

  if (rl.rlim_max != RLIM_INFINITY && want > rl.rlim_max)
    want = rl.rlim_max;
  if (current != RLIM_INFINITY && want <= current)
    CAMLreturn(Val_long((long)current)); /* already have at least this */

  /* Down from the target until one is accepted: the true per-process cap is not
     visible in rlim_max on every platform. */
  while (want > current) {
    struct rlimit attempt = rl;
    attempt.rlim_cur = want;
    if (setrlimit(RLIMIT_NOFILE, &attempt) == 0)
      CAMLreturn(Val_long((long)want));
    want /= 2;
  }
  CAMLreturn(Val_long((long)current));
#endif
}
