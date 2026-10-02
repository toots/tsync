#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <unistd.h>

/* Positioned I/O into off-heap buffers: bigarray data never moves, so the
   runtime lock is released around the call. */
CAMLprim value tsync_pread(value fd, value buf, value boff, value len, value foff) {
  CAMLparam5(fd, buf, boff, len, foff);
  char *p = (char *)Caml_ba_data_val(buf) + Long_val(boff);
  size_t n = Long_val(len);
  off_t o = Int64_val(foff);
  ssize_t r;
  caml_release_runtime_system();
  do { r = pread(Int_val(fd), p, n, o); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  if (r < 0) { errno = e; uerror("pread", Nothing); }
  CAMLreturn(Val_long(r));
}

CAMLprim value tsync_pwrite(value fd, value buf, value boff, value len, value foff) {
  CAMLparam5(fd, buf, boff, len, foff);
  char *p = (char *)Caml_ba_data_val(buf) + Long_val(boff);
  size_t n = Long_val(len);
  off_t o = Int64_val(foff);
  ssize_t r;
  caml_release_runtime_system();
  do { r = pwrite(Int_val(fd), p, n, o); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  if (r < 0) { errno = e; uerror("pwrite", Nothing); }
  CAMLreturn(Val_long(r));
}

CAMLprim value tsync_statvfs(value path) {
  CAMLparam1(path);
  CAMLlocal1(res);
  struct statvfs s;
  char *p = caml_stat_strdup(String_val(path));
  int r;
  caml_release_runtime_system();
  do { r = statvfs(p, &s); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(p);
  if (r < 0) { errno = e; uerror("statvfs", path); }
  res = caml_alloc_tuple(3);
  Store_field(res, 0, caml_copy_int64((int64_t)s.f_bavail * s.f_frsize));
  Store_field(res, 1, caml_copy_int64((int64_t)s.f_bfree * s.f_frsize));
  Store_field(res, 2, caml_copy_int64((int64_t)s.f_blocks * s.f_frsize));
  CAMLreturn(res);
}

/* A BSD lock is released when its holder dies, and not by an unrelated close
   of the same file. */
CAMLprim value tsync_flock(value fd, value exclusive, value block) {
  CAMLparam3(fd, exclusive, block);
  int op = (Bool_val(exclusive) ? LOCK_EX : LOCK_SH) | (Bool_val(block) ? 0 : LOCK_NB);
  int r;
  caml_release_runtime_system();
  do { r = flock(Int_val(fd), op); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  if (r < 0) {
    if (e == EWOULDBLOCK) CAMLreturn(Val_false);
    errno = e;
    uerror("flock", Nothing);
  }
  CAMLreturn(Val_true);
}

CAMLprim value tsync_funlock(value fd) {
  flock(Int_val(fd), LOCK_UN);
  return Val_unit;
}

CAMLprim value tsync_open_nofollow(value path) {
  CAMLparam1(path);
  char *p = caml_stat_strdup(String_val(path));
  int fd;
  caml_release_runtime_system();
  do { fd = open(p, O_RDONLY | O_CLOEXEC | O_NOFOLLOW); } while (fd < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(p);
  if (fd < 0) { errno = e; uerror("open", path); }
  CAMLreturn(Val_int(fd));
}

CAMLprim value tsync_pid_alive(value pid) {
  if (kill(Int_val(pid), 0) == 0) return Val_true;
  return Val_bool(errno == EPERM);
}

/* The errnos the OCaml Unix library does not name, as this platform numbers
   them: ESTALE, EDQUOT, ETXTBSY, ENOLINK, EREMOTEIO (-1 when absent). */
CAMLprim value tsync_errno_numbers(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(res);
  res = caml_alloc_tuple(5);
  Store_field(res, 0, Val_int(ESTALE));
  Store_field(res, 1, Val_int(EDQUOT));
  Store_field(res, 2, Val_int(ETXTBSY));
#ifdef ENOLINK
  Store_field(res, 3, Val_int(ENOLINK));
#else
  Store_field(res, 3, Val_int(-1));
#endif
#ifdef EREMOTEIO
  Store_field(res, 4, Val_int(EREMOTEIO));
#else
  Store_field(res, 4, Val_int(-1));
#endif
  CAMLreturn(res);
}

/* Bigstring helpers: no allocation, so the runtime lock stays held. */
CAMLprim value tsync_bigstring_memcmp(value a, value aoff, value b, value boff, value len) {
  return Val_int(memcmp((char *)Caml_ba_data_val(a) + Long_val(aoff),
                        (char *)Caml_ba_data_val(b) + Long_val(boff), Long_val(len)));
}

CAMLprim value tsync_bigstring_blit_from_bytes(value src, value soff, value dst, value doff, value len) {
  memcpy((char *)Caml_ba_data_val(dst) + Long_val(doff), Bytes_val(src) + Long_val(soff), Long_val(len));
  return Val_unit;
}

CAMLprim value tsync_bigstring_blit_to_bytes(value src, value soff, value dst, value doff, value len) {
  memcpy(Bytes_val(dst) + Long_val(doff), (char *)Caml_ba_data_val(src) + Long_val(soff), Long_val(len));
  return Val_unit;
}

/* Raise the soft descriptor limit toward the hard one, capped at target, never
   lowering it; answers the soft limit in force. */
CAMLprim value tsync_raise_nofile(value target) {
  struct rlimit r;
  if (getrlimit(RLIMIT_NOFILE, &r) < 0) uerror("getrlimit", Nothing);
  rlim_t want = (rlim_t)Long_val(target);
  if (r.rlim_max != RLIM_INFINITY && want > r.rlim_max) want = r.rlim_max;
  if (want > r.rlim_cur) {
    r.rlim_cur = want;
    if (setrlimit(RLIMIT_NOFILE, &r) < 0) uerror("setrlimit", Nothing);
  }
  return Val_long(r.rlim_cur);
}

#if defined(__linux__)

#include <linux/fs.h>
#include <sys/inotify.h>
#include <malloc.h>
#include <sys/ioctl.h>
#include <sys/statfs.h>
#include <sys/syscall.h>

CAMLprim value tsync_fsync(value fd) {
  CAMLparam1(fd);
  int r;
  caml_release_runtime_system();
  do { r = fsync(Int_val(fd)); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  if (r < 0) { errno = e; uerror("fsync", Nothing); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_reserve(value fd, value len) {
  CAMLparam2(fd, len);
  int r;
  caml_release_runtime_system();
  do { r = fallocate(Int_val(fd), 0, 0, Int64_val(len)); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  if (r < 0) {
    errno = (e == ENOTSUP || e == ENOSYS) ? EOPNOTSUPP : e;
    uerror("fallocate", Nothing);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_rename_noreplace(value src, value dst) {
  CAMLparam2(src, dst);
  char *s = caml_stat_strdup(String_val(src)), *d = caml_stat_strdup(String_val(dst));
  int r;
  caml_release_runtime_system();
  do {
    r = syscall(SYS_renameat2, AT_FDCWD, s, AT_FDCWD, d, 1 /* RENAME_NOREPLACE */);
  } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(s);
  caml_stat_free(d);
  if (r < 0) { errno = e; uerror("rename", dst); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_syncfs(value fd) {
  CAMLparam1(fd);
  caml_release_runtime_system();
  int r = syncfs(Int_val(fd)), e = errno;
  caml_acquire_runtime_system();
  if (r < 0) { errno = e; uerror("syncfs", Nothing); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_peer_uid(value fd) {
  CAMLparam1(fd);
  struct ucred c;
  socklen_t l = sizeof(c);
  if (getsockopt(Int_val(fd), SOL_SOCKET, SO_PEERCRED, &c, &l) < 0) uerror("getsockopt", Nothing);
  CAMLreturn(Val_int(c.uid));
}

CAMLprim value tsync_clone(value src, value dst) {
  CAMLparam2(src, dst);
  char *sp = caml_stat_strdup(String_val(src)), *dp = caml_stat_strdup(String_val(dst));
  const char *what = "open";
  int r = -1, e = 0, at_dst = 0;
  caml_release_runtime_system();
  int s = open(sp, O_RDONLY | O_CLOEXEC);
  if (s < 0) e = errno;
  else {
    int d = open(dp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    at_dst = 1;
    if (d < 0) e = errno;
    else {
      r = ioctl(d, FICLONE, s);
      e = errno;
      close(d);
      if (r < 0) { unlink(dp); what = "ficlone"; }
    }
    close(s);
  }
  caml_acquire_runtime_system();
  caml_stat_free(sp);
  caml_stat_free(dp);
  if (r < 0) { errno = e; uerror(what, at_dst ? dst : src); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_is_network_fs(value path) {
  CAMLparam1(path);
  struct statfs s;
  char *p = caml_stat_strdup(String_val(path));
  caml_release_runtime_system();
  int r = statfs(p, &s), e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(p);
  if (r < 0) { errno = e; uerror("statfs", path); }
  switch ((unsigned long)s.f_type) {
  case 0x6969:     /* NFS */
  case 0xFF534D42: /* CIFS */
  case 0xFE534D42: /* SMB2 */
  case 0x517B:     /* SMB */
  case 0x65735546: /* FUSE */
  case 0x564c:     /* NCP */
  case 0x6B414653: /* AFS */
    CAMLreturn(Val_true);
  default:
    CAMLreturn(Val_false);
  }
}

CAMLprim value tsync_is_macos(value unit) { return Val_false; }

/* Resident anonymous and file-backed bytes, from /proc/self/status. */
CAMLprim value tsync_memory_split(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(res);
  long anon = -1, file = -1;
  char line[256];
  FILE *f = fopen("/proc/self/status", "r");
  if (f) {
    while (fgets(line, sizeof line, f)) {
      sscanf(line, "RssAnon: %ld kB", &anon);
      sscanf(line, "RssFile: %ld kB", &file);
    }
    fclose(f);
  }
  res = caml_alloc_tuple(2);
  Store_field(res, 0, Val_long(anon < 0 ? -1 : anon * 1024));
  Store_field(res, 1, Val_long(file < 0 ? -1 : file * 1024));
  CAMLreturn(res);
}

/* Hands the allocator's free memory back to the kernel. */
CAMLprim value tsync_malloc_trim(value unit) {
  malloc_trim(0);
  return Val_unit;
}

/* 01 §14: a non-recursive watch of a directory's entries. */
CAMLprim value tsync_watch_open(value path) {
  CAMLparam1(path);
  int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (fd < 0) uerror("inotify_init1", path);
  if (inotify_add_watch(fd, String_val(path),
                        IN_CREATE | IN_MOVED_TO | IN_CLOSE_WRITE | IN_DELETE |
                            IN_MOVED_FROM | IN_DELETE_SELF | IN_MOVE_SELF) < 0) {
    int e = errno;
    close(fd);
    errno = e;
    uerror("inotify_add_watch", path);
  }
  CAMLreturn(Val_int(fd));
}

/* The names of pending events, and whether the directory went away; a
   bounded number of reads, so a registration that never clears cannot spin. */
CAMLprim value tsync_watch_drain(value vfd) {
  CAMLparam1(vfd);
  CAMLlocal3(names, cell, res);
  char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
  int gone = 0;
  names = Val_emptylist;
  for (int reads = 0; reads < 64; reads++) {
    ssize_t n = read(Int_val(vfd), buf, sizeof buf);
    if (n <= 0) break;
    for (char *p = buf; p < buf + n;) {
      struct inotify_event *ev = (struct inotify_event *)p;
      if (ev->mask & (IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED)) gone = 1;
      if (ev->len > 0) {
        cell = caml_alloc(2, 0);
        Store_field(cell, 0, caml_copy_string(ev->name));
        Store_field(cell, 1, names);
        names = cell;
      }
      p += sizeof(struct inotify_event) + ev->len;
    }
  }
  res = caml_alloc_tuple(2);
  Store_field(res, 0, names);
  Store_field(res, 1, Val_bool(gone));
  CAMLreturn(res);
}

#elif defined(__APPLE__)

#include <mach/mach.h>
#include <malloc/malloc.h>
#include <sys/clonefile.h>
#include <sys/mount.h>
#include <sys/ucred.h>

/* A plain fsync does not reach the medium on macOS. */
CAMLprim value tsync_fsync(value fd) {
  CAMLparam1(fd);
  int r;
  caml_release_runtime_system();
  do { r = fcntl(Int_val(fd), F_FULLFSYNC); } while (r < 0 && errno == EINTR);
  if (r < 0) do { r = fsync(Int_val(fd)); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  if (r < 0) { errno = e; uerror("fsync", Nothing); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_reserve(value fd, value len) {
  CAMLparam2(fd, len);
  fstore_t st = {F_ALLOCATEALL, F_PEOFPOSMODE, 0, Int64_val(len), 0};
  int r;
  caml_release_runtime_system();
  r = fcntl(Int_val(fd), F_PREALLOCATE, &st);
  if (r >= 0) r = ftruncate(Int_val(fd), Int64_val(len));
  int e = errno;
  caml_acquire_runtime_system();
  if (r < 0) {
    errno = (e == ENOTSUP || e == ENOSYS) ? EOPNOTSUPP : e;
    uerror("fallocate", Nothing);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_rename_noreplace(value src, value dst) {
  CAMLparam2(src, dst);
  char *s = caml_stat_strdup(String_val(src)), *d = caml_stat_strdup(String_val(dst));
  int r;
  caml_release_runtime_system();
  do { r = renamex_np(s, d, RENAME_EXCL); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(s);
  caml_stat_free(d);
  if (r < 0) { errno = e; uerror("rename", dst); }
  CAMLreturn(Val_unit);
}

/* No syncfs here: sync flushes every filesystem. */
CAMLprim value tsync_syncfs(value fd) {
  CAMLparam1(fd);
  caml_release_runtime_system();
  sync();
  caml_acquire_runtime_system();
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_peer_uid(value fd) {
  CAMLparam1(fd);
  uid_t u;
  gid_t g;
  if (getpeereid(Int_val(fd), &u, &g) < 0) uerror("getpeereid", Nothing);
  CAMLreturn(Val_int(u));
}

CAMLprim value tsync_clone(value src, value dst) {
  CAMLparam2(src, dst);
  char *s = caml_stat_strdup(String_val(src)), *d = caml_stat_strdup(String_val(dst));
  caml_release_runtime_system();
  int r = clonefile(s, d, 0), e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(s);
  caml_stat_free(d);
  if (r < 0) { errno = e; uerror("clonefile", dst); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_is_network_fs(value path) {
  CAMLparam1(path);
  struct statfs s;
  char *p = caml_stat_strdup(String_val(path));
  caml_release_runtime_system();
  int r = statfs(p, &s), e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(p);
  if (r < 0) { errno = e; uerror("statfs", path); }
  CAMLreturn(Val_bool(!(s.f_flags & MNT_LOCAL)));
}

CAMLprim value tsync_is_macos(value unit) { return Val_true; }

/* Resident anonymous (internal) and file-backed (external) bytes. */
CAMLprim value tsync_memory_split(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(res);
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  long anon = -1, file = -1;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
    anon = (long)info.internal;
    file = (long)info.external;
  }
  res = caml_alloc_tuple(2);
  Store_field(res, 0, Val_long(anon));
  Store_field(res, 1, Val_long(file));
  CAMLreturn(res);
}

CAMLprim value tsync_malloc_trim(value unit) {
  malloc_zone_pressure_relief(NULL, 0);
  return Val_unit;
}

/* No watch here: kqueue reports no names, so it could not discard the
   consumer's own temporaries (01 §14); the consumer polls. */
CAMLprim value tsync_watch_open(value path) {
  CAMLparam1(path);
  errno = ENOSYS;
  uerror("watch", path);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_watch_drain(value vfd) {
  CAMLparam1(vfd);
  CAMLlocal1(res);
  res = caml_alloc_tuple(2);
  Store_field(res, 0, Val_emptylist);
  Store_field(res, 1, Val_true);
  CAMLreturn(res);
}

#endif

/* The terminal's width in columns, 0 when the descriptor is not a terminal. */
CAMLprim value tsync_terminal_columns(value fd) {
  struct winsize w;
  if (ioctl(Int_val(fd), TIOCGWINSZ, &w) < 0) return Val_int(0);
  return Val_int(w.ws_col);
}

/* Only a mapping's pages: on a malloc'd buffer MADV_DONTNEED would zero data.
   The mappings are private and never written, so a later read faults the
   pages back in from the file. */
CAMLprim value tsync_drop_mapped_pages(value v) {
  struct caml_ba_array *b = Caml_ba_array_val(v);
  if ((b->flags & CAML_BA_MANAGED_MASK) == CAML_BA_MAPPED_FILE && b->data != NULL) {
    uintptr_t page = (uintptr_t)sysconf(_SC_PAGESIZE);
    uintptr_t start = (uintptr_t)b->data & ~(page - 1);
    size_t len = caml_ba_byte_size(b) + ((uintptr_t)b->data - start);
    if (len > 0) madvise((void *)start, len, MADV_DONTNEED);
  }
  return Val_unit;
}
