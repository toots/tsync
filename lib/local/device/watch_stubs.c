/* Being told a directory changed, reduced to what a caller that re-reads anyway
 * needs: a descriptor that becomes readable, and a way to empty it.
 *
 * Both platforms in one file, as descriptors_stubs.c has both of its: what
 * differs is which syscalls name the idea, not the idea.
 *
 * The one thing a name is read for: tsync's own scratch files. A read takes a
 * reflink snapshot through a temp file in the object's own directory, so a
 * store that reports those wakes the reader that made them, which reads again
 * — a loop that ends in a box with no memory rather than in an error.
 *
 * ponytail: no errno beyond what caml_uerror carries, and no decoding past the
 * name. Every failure means the same thing to the caller — go back to asking. */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

#include <errno.h>
#include <string.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/inotify.h>

/* IN_CLOSE_WRITE rather than IN_MODIFY: a writer that opens, writes and closes
 * would otherwise wake a reader once per write() rather than once per file. */
#define TSYNC_WATCH_EVENTS (IN_CREATE | IN_MOVED_TO | IN_CLOSE_WRITE)

#elif defined(__APPLE__)
#include <fcntl.h>
#include <sys/event.h>
#include <sys/time.h>

/* NOTE_LINK is what a rename into the directory raises there; NOTE_WRITE covers
 * a name created or removed. The directory's own removal ends the watch, which
 * the caller reads as a directory it can no longer watch and falls back from. */
#define TSYNC_WATCH_EVENTS (NOTE_WRITE | NOTE_LINK | NOTE_DELETE | NOTE_RENAME)
#endif

/* Syscalls that touch no disk, so the runtime lock is held throughout, as it is
 * for the clone ioctl next door. */
CAMLprim value tsync_watch_open_dir(value _directory_path) {
  CAMLparam1(_directory_path);
  CAMLlocal1(_descriptors);

#if defined(__linux__)
  int notify_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (notify_fd < 0)
    caml_uerror("inotify_init1", _directory_path);
  if (inotify_add_watch(notify_fd, String_val(_directory_path),
                        TSYNC_WATCH_EVENTS) < 0) {
    int add_errno = errno;
    close(notify_fd);
    errno = add_errno;
    caml_uerror("inotify_add_watch", _directory_path);
  }
  _descriptors = caml_alloc_tuple(1);
  Store_field(_descriptors, 0, Val_int(notify_fd));

#elif defined(__APPLE__)
  /* O_EVTONLY asks for no access beyond being told about it, so this does not
   * hold the directory against an unmount the way a read descriptor would. */
  int directory_fd = open(String_val(_directory_path), O_EVTONLY | O_CLOEXEC);
  if (directory_fd < 0)
    caml_uerror("open", _directory_path);
  int queue_fd = kqueue();
  if (queue_fd < 0) {
    int queue_errno = errno;
    close(directory_fd);
    errno = queue_errno;
    caml_uerror("kqueue", _directory_path);
  }
  struct kevent registration;
  /* EV_CLEAR, or the queue stays readable once anything has happened and every
   * wait after the first returns at once. */
  EV_SET(&registration, directory_fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
         TSYNC_WATCH_EVENTS, 0, NULL);
  if (kevent(queue_fd, &registration, 1, NULL, 0, NULL) < 0) {
    int register_errno = errno;
    close(queue_fd);
    close(directory_fd);
    errno = register_errno;
    caml_uerror("kevent", _directory_path);
  }
  _descriptors = caml_alloc_tuple(2);
  Store_field(_descriptors, 0, Val_int(queue_fd));
  Store_field(_descriptors, 1, Val_int(directory_fd));

#else
  errno = ENOSYS;
  caml_uerror("watch", _directory_path);
  _descriptors = Val_unit;
#endif

  CAMLreturn(_descriptors);
}

/* Bounded, because draining is best-effort: what is left makes the descriptor
 * readable again, which costs the caller a wake it treats as a hint anyway. An
 * unbounded loop here spins inside C holding the runtime lock the moment an
 * event will not clear — a registration missing EV_CLEAR does exactly that, and
 * nothing above can time it out. */
#define TSYNC_WATCH_DRAIN_PASSES 64

#if defined(__linux__)
/* Matches Filename.is_temp_name, which is where the spelling is decided; it is
 * repeated here because a name is read in C and nowhere else. */
static int tsync_watch_is_temp_name(const char *name, int length) {
  static const char prefix[] = ".tsync-tmp-";
  static const char suffix[] = ".tmp";
  int prefix_length = (int)sizeof prefix - 1;
  int suffix_length = (int)sizeof suffix - 1;
  if (length < prefix_length + suffix_length)
    return 0;
  if (memcmp(name, prefix, prefix_length) != 0)
    return 0;
  return memcmp(name + length - suffix_length, suffix, suffix_length) == 0;
}
#endif

/* Whether anything the caller would call a change arrived. */
CAMLprim value tsync_watch_drain(value _watch_fd) {
  CAMLparam1(_watch_fd);
  int reportable = 0;

#if defined(__linux__)
  /* Reads until the descriptor reports EAGAIN, having been opened non-blocking.
   * A short read cannot happen: the kernel refuses a partial event and answers
   * EINVAL for a buffer too small for the next one, which this is not. */
  /* Aligned, because each event is read back through a struct pointer. */
  char events[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
  for (int pass = 0; pass < TSYNC_WATCH_DRAIN_PASSES; pass++) {
    ssize_t bytes_read = read(Int_val(_watch_fd), events, sizeof events);
    if (bytes_read < 0 && errno == EINTR)
      continue;
    if (bytes_read <= 0)
      break;
    for (char *at = events; at < events + bytes_read;) {
      struct inotify_event *event = (struct inotify_event *)at;
      /* No name at all is an event about the directory itself, which is a
       * change to report: only a name this process knows for its own scratch
       * is not. */
      if (event->len == 0 ||
          !tsync_watch_is_temp_name(event->name, (int)strnlen(event->name,
                                                              event->len)))
        reportable = 1;
      at += sizeof(struct inotify_event) + event->len;
    }
  }

#elif defined(__APPLE__)
  /* A zero timeout, so this reports what is already queued rather than waiting
   * for the next one. A vnode event carries no name, so every one of them is a
   * change as far as this can tell. */
  struct kevent pending;
  struct timespec immediately = {0, 0};
  for (int pass = 0; pass < TSYNC_WATCH_DRAIN_PASSES; pass++) {
    int taken = kevent(Int_val(_watch_fd), NULL, 0, &pending, 1, &immediately);
    if (taken < 0 && errno == EINTR)
      continue;
    if (taken <= 0)
      break;
    reportable = 1;
  }
#endif

  CAMLreturn(Val_bool(reportable));
}
