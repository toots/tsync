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
  if (Bool_val(block)) caml_release_runtime_system();
  do { r = flock(Int_val(fd), op); } while (r < 0 && errno == EINTR);
  int e = errno;
  if (Bool_val(block)) caml_acquire_runtime_system();
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
  int r;
  do {
    r = syscall(SYS_renameat2, AT_FDCWD, String_val(src), AT_FDCWD, String_val(dst), 1 /* RENAME_NOREPLACE */);
  } while (r < 0 && errno == EINTR);
  if (r < 0) uerror("rename", dst);
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
  int s = open(String_val(src), O_RDONLY | O_CLOEXEC);
  if (s < 0) uerror("open", src);
  int d = open(String_val(dst), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (d < 0) { int e = errno; close(s); errno = e; uerror("open", dst); }
  int r = ioctl(d, FICLONE, s);
  int e = errno;
  close(s);
  close(d);
  if (r < 0) { unlink(String_val(dst)); errno = e; uerror("ficlone", dst); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_is_network_fs(value path) {
  CAMLparam1(path);
  struct statfs s;
  if (statfs(String_val(path), &s) < 0) uerror("statfs", path);
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
  int r;
  do { r = renamex_np(String_val(src), String_val(dst), RENAME_EXCL); } while (r < 0 && errno == EINTR);
  if (r < 0) uerror("rename", dst);
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
  if (clonefile(String_val(src), String_val(dst), 0) < 0) uerror("clonefile", dst);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_is_network_fs(value path) {
  CAMLparam1(path);
  struct statfs s;
  if (statfs(String_val(path), &s) < 0) uerror("statfs", path);
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

#endif
