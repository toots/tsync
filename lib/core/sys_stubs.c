#define _GNU_SOURCE
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

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

/* The errnos the OCaml Unix library does not name, as this platform numbers
   them: ESTALE, EDQUOT, ETXTBSY, ENOLINK, EREMOTEIO (-1 when absent). */
CAMLprim value tsync_errno_numbers(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(res);
  res = caml_alloc_tuple(5);
#ifdef ESTALE
  Store_field(res, 0, Val_int(ESTALE));
#else
  Store_field(res, 0, Val_int(-1));
#endif
#ifdef EDQUOT
  Store_field(res, 1, Val_int(EDQUOT));
#else
  Store_field(res, 1, Val_int(-1));
#endif
#ifdef ETXTBSY
  Store_field(res, 2, Val_int(ETXTBSY));
#else
  Store_field(res, 2, Val_int(-1));
#endif
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

#if defined(_WIN32)

#include <winsock2.h>
#include <windows.h>
#include <aclapi.h>
#include <afunix.h>
#include <bcrypt.h>
#include <malloc.h>
#include <wtsapi32.h>

static void win_fail(DWORD err, const char *what, value arg) {
  win32_maperr(err);
  uerror(what, arg);
}

static wchar_t *wide_path(value path) {
  int n = MultiByteToWideChar(CP_UTF8, 0, String_val(path), -1, NULL, 0);
  if (n <= 0) { errno = EINVAL; uerror("path", path); }
  wchar_t *w = caml_stat_alloc(n * sizeof(wchar_t));
  MultiByteToWideChar(CP_UTF8, 0, String_val(path), -1, w, n);
  return w;
}

static DWORD io_length(value len) {
  intnat n = Long_val(len);
  return n > 0x7fffffff ? 0x7fffffff : (DWORD)n;
}

static OVERLAPPED at_offset(int64_t off) {
  OVERLAPPED o = {0};
  o.Offset = (DWORD)off;
  o.OffsetHigh = (DWORD)(off >> 32);
  return o;
}

CAMLprim value tsync_pread(value fd, value buf, value boff, value len, value foff) {
  CAMLparam5(fd, buf, boff, len, foff);
  HANDLE h = Handle_val(fd);
  char *p = (char *)Caml_ba_data_val(buf) + Long_val(boff);
  DWORD n = io_length(len), done = 0;
  OVERLAPPED o = at_offset(Int64_val(foff));
  caml_release_runtime_system();
  BOOL ok = ReadFile(h, p, n, &done, &o);
  DWORD err = ok ? 0 : GetLastError();
  caml_acquire_runtime_system();
  if (!ok && err != ERROR_HANDLE_EOF) win_fail(err, "pread", Nothing);
  CAMLreturn(Val_long(done));
}

CAMLprim value tsync_pwrite(value fd, value buf, value boff, value len, value foff) {
  CAMLparam5(fd, buf, boff, len, foff);
  HANDLE h = Handle_val(fd);
  char *p = (char *)Caml_ba_data_val(buf) + Long_val(boff);
  DWORD n = io_length(len), done = 0;
  OVERLAPPED o = at_offset(Int64_val(foff));
  caml_release_runtime_system();
  BOOL ok = WriteFile(h, p, n, &done, &o);
  DWORD err = ok ? 0 : GetLastError();
  caml_acquire_runtime_system();
  if (!ok) win_fail(err, "pwrite", Nothing);
  CAMLreturn(Val_long(done));
}

CAMLprim value tsync_statvfs(value path) {
  CAMLparam1(path);
  CAMLlocal1(res);
  wchar_t *p = wide_path(path);
  ULARGE_INTEGER avail, total, free_bytes;
  caml_release_runtime_system();
  BOOL ok = GetDiskFreeSpaceExW(p, &avail, &total, &free_bytes);
  DWORD err = ok ? 0 : GetLastError();
  caml_acquire_runtime_system();
  caml_stat_free(p);
  if (!ok) win_fail(err, "statvfs", path);
  res = caml_alloc_tuple(3);
  Store_field(res, 0, caml_copy_int64((int64_t)avail.QuadPart));
  Store_field(res, 1, caml_copy_int64((int64_t)free_bytes.QuadPart));
  Store_field(res, 2, caml_copy_int64((int64_t)total.QuadPart));
  CAMLreturn(res);
}

/* Windows byte-range locks are mandatory, so the lock covers one byte far past
   the end of the file: readers of the holder record are never refused. */
#define LOCK_OFFSET 0x4000000000000000LL

CAMLprim value tsync_flock(value fd, value exclusive, value block) {
  CAMLparam3(fd, exclusive, block);
  HANDLE h = Handle_val(fd);
  DWORD flags = (Bool_val(exclusive) ? LOCKFILE_EXCLUSIVE_LOCK : 0) |
                (Bool_val(block) ? 0 : LOCKFILE_FAIL_IMMEDIATELY);
  OVERLAPPED o = at_offset(LOCK_OFFSET);
  caml_release_runtime_system();
  BOOL ok = LockFileEx(h, flags, 0, 1, 0, &o);
  DWORD err = ok ? 0 : GetLastError();
  caml_acquire_runtime_system();
  if (!ok) {
    if (err == ERROR_LOCK_VIOLATION || err == ERROR_IO_PENDING) CAMLreturn(Val_false);
    win_fail(err, "flock", Nothing);
  }
  CAMLreturn(Val_true);
}

CAMLprim value tsync_funlock(value fd) {
  OVERLAPPED o = at_offset(LOCK_OFFSET);
  UnlockFileEx(Handle_val(fd), 0, 1, 0, &o);
  return Val_unit;
}

static int is_link(HANDLE h) {
  FILE_ATTRIBUTE_TAG_INFO info;
  if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &info, sizeof info)) return 0;
  return (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
         (info.ReparseTag == IO_REPARSE_TAG_SYMLINK || info.ReparseTag == IO_REPARSE_TAG_MOUNT_POINT);
}

CAMLprim value tsync_open_nofollow(value path) {
  CAMLparam1(path);
  wchar_t *p = wide_path(path);
  caml_release_runtime_system();
  HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING,
                         FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
  DWORD err = h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
  int link = h != INVALID_HANDLE_VALUE && is_link(h);
  if (link) CloseHandle(h);
  caml_acquire_runtime_system();
  caml_stat_free(p);
  if (h == INVALID_HANDLE_VALUE) win_fail(err, "open", path);
  if (link) { errno = ELOOP; uerror("open", path); }
  CAMLreturn(win_alloc_handle(h));
}

CAMLprim value tsync_pid_alive(value pid) {
  HANDLE h = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)Int_val(pid));
  if (h == NULL) return Val_bool(GetLastError() == ERROR_ACCESS_DENIED);
  DWORD r = WaitForSingleObject(h, 0);
  CloseHandle(h);
  return Val_bool(r == WAIT_TIMEOUT);
}

CAMLprim value tsync_raise_nofile(value target) { return target; }

/* A message the window handles arrives inside GetMessage, which does not
   return for it: the procedure posts an empty message to end the wait. */
static int session_pending = -1;
static HWND session_window;

static LRESULT CALLBACK session_procedure(HWND window, UINT message, WPARAM w, LPARAM l) {
  int event = -1;
  if (message == WM_QUERYENDSESSION) return TRUE;
  if (message == WM_ENDSESSION && w) event = 0;
  if (message == WM_WTSSESSION_CHANGE && w == WTS_SESSION_LOCK) event = 1;
  if (message == WM_WTSSESSION_CHANGE && w == WTS_SESSION_UNLOCK) event = 2;
  if (event >= 0) {
    session_pending = event;
    PostMessageW(window, WM_NULL, 0, 0);
    return 0;
  }
  return DefWindowProcW(window, message, w, l);
}

/* A top-level window, since a message-only one is not told the session ends. */
CAMLprim value tsync_session_event(value unit) {
  CAMLparam1(unit);
  if (session_window == NULL) {
    WNDCLASSW class = {0};
    class.lpfnWndProc = session_procedure;
    class.hInstance = GetModuleHandleW(NULL);
    class.lpszClassName = L"tsync-session";
    if (!RegisterClassW(&class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
      win_fail(GetLastError(), "session", Nothing);
    session_window = CreateWindowExW(0, L"tsync-session", L"tsync", 0, 0, 0, 0, 0, NULL, NULL,
                                     class.hInstance, NULL);
    if (session_window == NULL) win_fail(GetLastError(), "session", Nothing);
    WTSRegisterSessionNotification(session_window, NOTIFY_FOR_THIS_SESSION);
  }
  int event = -1;
  BOOL got = TRUE;
  caml_release_runtime_system();
  while (event < 0 && got > 0) {
    MSG message;
    got = GetMessageW(&message, NULL, 0, 0);
    if (got > 0) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
      event = session_pending;
      session_pending = -1;
    }
  }
  DWORD err = got < 0 ? GetLastError() : 0;
  caml_acquire_runtime_system();
  if (got < 0) win_fail(err, "session", Nothing);
  CAMLreturn(Val_int(got == 0 ? 0 : event));
}

/* One job per process, which ends its members when its last handle closes:
   the children end with this process, however it ends. */
static HANDLE children_job;

CAMLprim value tsync_end_with_this_process(value pid) {
  CAMLparam1(pid);
  if (children_job == NULL) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    HANDLE created = CreateJobObjectW(NULL, NULL);
    if (created == NULL ||
        !SetInformationJobObject(created, JobObjectExtendedLimitInformation, &limits,
                                 sizeof limits)) {
      DWORD err = GetLastError();
      if (created) CloseHandle(created);
      win_fail(err, "job", Nothing);
    }
    if (InterlockedCompareExchangePointer((PVOID *)&children_job, created, NULL) != NULL)
      CloseHandle(created);
  }
  /* What Unix.create_process returns on Windows is the child's handle, which
     Unix.waitpid closes later. */
  if (!AssignProcessToJobObject(children_job, (HANDLE)Long_val(pid)))
    win_fail(GetLastError(), "job", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_system_random(value len) {
  CAMLparam1(len);
  CAMLlocal1(res);
  res = caml_alloc_string(Long_val(len));
  NTSTATUS status = BCryptGenRandom(NULL, (PUCHAR)Bytes_val(res), (ULONG)Long_val(len),
                                    BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  if (!BCRYPT_SUCCESS(status)) caml_failwith("BCryptGenRandom failed");
  CAMLreturn(res);
}

/* A flush needs a handle that may write, where POSIX flushes through any
   descriptor: a read-only one is reopened for the flush. */
CAMLprim value tsync_fsync(value fd) {
  CAMLparam1(fd);
  HANDLE h = Handle_val(fd);
  caml_release_runtime_system();
  BOOL ok = FlushFileBuffers(h);
  DWORD err = ok ? 0 : GetLastError();
  if (err == ERROR_ACCESS_DENIED) {
    HANDLE writable = ReOpenFile(h, GENERIC_WRITE,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0);
    if (writable == INVALID_HANDLE_VALUE) err = GetLastError();
    else {
      ok = FlushFileBuffers(writable);
      err = ok ? 0 : GetLastError();
      CloseHandle(writable);
    }
  }
  caml_acquire_runtime_system();
  if (!ok) win_fail(err, "fsync", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_reserve(value fd, value len) {
  CAMLparam2(fd, len);
  HANDLE h = Handle_val(fd);
  FILE_ALLOCATION_INFO alloc;
  FILE_END_OF_FILE_INFO eof;
  LARGE_INTEGER size;
  alloc.AllocationSize.QuadPart = Int64_val(len);
  eof.EndOfFile.QuadPart = Int64_val(len);
  caml_release_runtime_system();
  BOOL ok = SetFileInformationByHandle(h, FileAllocationInfo, &alloc, sizeof alloc) &&
            GetFileSizeEx(h, &size);
  if (ok && size.QuadPart < eof.EndOfFile.QuadPart)
    ok = SetFileInformationByHandle(h, FileEndOfFileInfo, &eof, sizeof eof);
  DWORD err = ok ? 0 : GetLastError();
  caml_acquire_runtime_system();
  if (!ok) win_fail(err, "fallocate", Nothing);
  CAMLreturn(Val_unit);
}

#ifndef FILE_RENAME_FLAG_REPLACE_IF_EXISTS
#define FILE_RENAME_FLAG_REPLACE_IF_EXISTS 0x1
#define FILE_RENAME_FLAG_POSIX_SEMANTICS 0x2
#endif
#define FILE_RENAME_INFO_EX ((FILE_INFO_BY_HANDLE_CLASS)22)

/* The rename call takes the destination as an extended-length path, which
   names a local drive as \\?\C:\ and a share as \\?\UNC\server\. */
static wchar_t *extended_path(const wchar_t *path, DWORD *length) {
  DWORD full = GetFullPathNameW(path, 0, NULL, NULL);
  wchar_t *absolute = full ? caml_stat_alloc_noexc(full * sizeof(wchar_t)) : NULL;
  if (absolute == NULL || GetFullPathNameW(path, full, absolute, NULL) == 0) {
    caml_stat_free(absolute);
    return NULL;
  }
  const wchar_t *prefix = L"\\\\?\\", *rest = absolute;
  if (wcsncmp(absolute, L"\\\\?\\", 4) == 0) prefix = L"";
  else if (wcsncmp(absolute, L"\\\\", 2) == 0) {
    prefix = L"\\\\?\\UNC\\";
    rest = absolute + 2;
  }
  *length = (DWORD)(wcslen(prefix) + wcslen(rest));
  wchar_t *extended = caml_stat_alloc_noexc((*length + 1) * sizeof(wchar_t));
  if (extended != NULL) {
    wcscpy(extended, prefix);
    wcscat(extended, rest);
  }
  caml_stat_free(absolute);
  return extended;
}

/* POSIX semantics replace a destination that is open; the request's flags
   word sits where older headers declare only ReplaceIfExists. */
CAMLprim value tsync_rename(value src, value dst) {
  CAMLparam2(src, dst);
  wchar_t *s = wide_path(src), *d = wide_path(dst);
  DWORD length = 0;
  wchar_t *target = extended_path(d, &length);
  size_t size = sizeof(FILE_RENAME_INFO) + length * sizeof(wchar_t);
  FILE_RENAME_INFO *info = target ? caml_stat_calloc_noexc(1, size) : NULL;
  if (info == NULL) {
    DWORD err = target ? ERROR_NOT_ENOUGH_MEMORY : GetLastError();
    caml_stat_free(s);
    caml_stat_free(d);
    caml_stat_free(target);
    win_fail(err ? err : ERROR_NOT_ENOUGH_MEMORY, "rename", src);
  }
  memcpy(info->FileName, target, (length + 1) * sizeof(wchar_t));
  caml_stat_free(target);
  DWORD flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS;
  memcpy(info, &flags, sizeof flags);
  info->FileNameLength = length * sizeof(wchar_t);
  caml_release_runtime_system();
  HANDLE h = CreateFileW(s, DELETE | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                         NULL);
  BOOL ok = h != INVALID_HANDLE_VALUE;
  DWORD err = ok ? 0 : GetLastError();
  if (ok) {
    ok = SetFileInformationByHandle(h, FILE_RENAME_INFO_EX, info, (DWORD)size);
    err = ok ? 0 : GetLastError();
    CloseHandle(h);
  }
  caml_acquire_runtime_system();
  caml_stat_free(s);
  caml_stat_free(d);
  caml_stat_free(info);
  if (!ok) win_fail(err, "rename", src);
  CAMLreturn(Val_unit);
}

#define FILE_DISPOSITION_INFO_EX ((FILE_INFO_BY_HANDLE_CLASS)21)
#define DISPOSITION_DELETE 0x1
#define DISPOSITION_POSIX_SEMANTICS 0x2
#define DISPOSITION_IGNORE_READONLY 0x10

/* POSIX semantics take the name away at once, open handles or not. */
CAMLprim value tsync_unlink(value path) {
  CAMLparam1(path);
  wchar_t *p = wide_path(path);
  DWORD flags = DISPOSITION_DELETE | DISPOSITION_POSIX_SEMANTICS | DISPOSITION_IGNORE_READONLY;
  caml_release_runtime_system();
  HANDLE h = CreateFileW(p, DELETE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                         NULL);
  BOOL ok = h != INVALID_HANDLE_VALUE;
  DWORD err = ok ? 0 : GetLastError();
  int directory = 0;
  if (ok) {
    FILE_BASIC_INFO info;
    directory = GetFileInformationByHandleEx(h, FileBasicInfo, &info, sizeof info) &&
                (info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY);
    if (!directory) {
      ok = SetFileInformationByHandle(h, FILE_DISPOSITION_INFO_EX, &flags, sizeof flags);
      err = ok ? 0 : GetLastError();
    }
    CloseHandle(h);
  }
  caml_acquire_runtime_system();
  caml_stat_free(p);
  if (directory) { errno = EISDIR; uerror("unlink", path); }
  if (!ok) win_fail(err, "unlink", path);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_rename_noreplace(value src, value dst) {
  CAMLparam2(src, dst);
  wchar_t *s = wide_path(src), *d = wide_path(dst);
  caml_release_runtime_system();
  BOOL ok = MoveFileExW(s, d, MOVEFILE_WRITE_THROUGH);
  DWORD err = ok ? 0 : GetLastError();
  caml_acquire_runtime_system();
  caml_stat_free(s);
  caml_stat_free(d);
  if (!ok) win_fail(err, "rename", dst);
  CAMLreturn(Val_unit);
}

/* Flushing a volume needs administrator rights; durability rests on the
   per-file flushes (cloud-files §5.1). */
CAMLprim value tsync_syncfs(value fd) { return Val_unit; }

static int process_user(HANDLE process, char *buf, DWORD size) {
  HANDLE token;
  DWORD needed;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token)) return 0;
  BOOL ok = GetTokenInformation(token, TokenUser, buf, size, &needed);
  CloseHandle(token);
  return ok;
}

CAMLprim value tsync_peer_same_user(value fd) {
  CAMLparam1(fd);
  ULONG pid = 0;
  DWORD out = 0;
  char mine[256], theirs[256];
  if (WSAIoctl(Socket_val(fd), SIO_AF_UNIX_GETPEERPID, NULL, 0, &pid, sizeof pid, &out, NULL, NULL) != 0)
    win_fail(WSAGetLastError(), "getpeerpid", Nothing);
  HANDLE peer = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (peer == NULL) CAMLreturn(Val_false);
  int same = process_user(peer, theirs, sizeof theirs) &&
             process_user(GetCurrentProcess(), mine, sizeof mine) &&
             EqualSid(((TOKEN_USER *)theirs)->User.Sid, ((TOKEN_USER *)mine)->User.Sid);
  CloseHandle(peer);
  CAMLreturn(Val_bool(same));
}

/* security-model §7.1: owned by the user, with a protected access list that
   allows no one else. */
CAMLprim value tsync_is_private(value path) {
  CAMLparam1(path);
  wchar_t *p = wide_path(path);
  PSID owner = NULL;
  PACL dacl = NULL;
  PSECURITY_DESCRIPTOR sd = NULL;
  char me[256];
  DWORD err = GetNamedSecurityInfoW(p, SE_FILE_OBJECT,
                                    OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                                    &owner, NULL, &dacl, NULL, &sd);
  caml_stat_free(p);
  if (err != ERROR_SUCCESS) win_fail(err, "is_private", path);
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision;
  int private_ = dacl != NULL && process_user(GetCurrentProcess(), me, sizeof me) &&
                 GetSecurityDescriptorControl(sd, &control, &revision) &&
                 (control & SE_DACL_PROTECTED) &&
                 EqualSid(owner, ((TOKEN_USER *)me)->User.Sid);
  for (DWORD i = 0; private_ && i < dacl->AceCount; i++) {
    ACE_HEADER *ace;
    if (!GetAce(dacl, i, (void **)&ace)) private_ = 0;
    else if (ace->AceType == ACCESS_ALLOWED_ACE_TYPE)
      private_ = EqualSid((PSID)&((ACCESS_ALLOWED_ACE *)ace)->SidStart,
                          ((TOKEN_USER *)me)->User.Sid);
    else if (ace->AceType != ACCESS_DENIED_ACE_TYPE)
      private_ = 0;
  }
  LocalFree(sd);
  CAMLreturn(Val_bool(private_));
}

CAMLprim value tsync_owned_by_this_user(value path) {
  CAMLparam1(path);
  wchar_t *p = wide_path(path);
  PSID owner = NULL;
  PSECURITY_DESCRIPTOR sd = NULL;
  char me[256];
  DWORD err = GetNamedSecurityInfoW(p, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &owner,
                                    NULL, NULL, NULL, &sd);
  caml_stat_free(p);
  if (err != ERROR_SUCCESS) win_fail(err, "owner", path);
  int mine = process_user(GetCurrentProcess(), me, sizeof me) &&
             EqualSid(owner, ((TOKEN_USER *)me)->User.Sid);
  LocalFree(sd);
  CAMLreturn(Val_bool(mine));
}

CAMLprim value tsync_make_private(value path) {
  CAMLparam1(path);
  char me[256];
  if (!process_user(GetCurrentProcess(), me, sizeof me))
    win_fail(GetLastError(), "make_private", path);
  PSID user = ((TOKEN_USER *)me)->User.Sid;
  wchar_t *p = wide_path(path);
  DWORD attributes = GetFileAttributesW(p);
  EXPLICIT_ACCESSW access = {0};
  access.grfAccessPermissions = GENERIC_ALL;
  access.grfAccessMode = SET_ACCESS;
  access.grfInheritance =
      attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY)
          ? SUB_CONTAINERS_AND_OBJECTS_INHERIT
          : NO_INHERITANCE;
  access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
  access.Trustee.TrusteeType = TRUSTEE_IS_USER;
  access.Trustee.ptstrName = (LPWSTR)user;
  PACL acl = NULL;
  DWORD err = attributes == INVALID_FILE_ATTRIBUTES ? GetLastError()
                                                    : SetEntriesInAclW(1, &access, NULL, &acl);
  if (err == ERROR_SUCCESS) {
    err = SetNamedSecurityInfoW(p, SE_FILE_OBJECT,
                                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION |
                                    PROTECTED_DACL_SECURITY_INFORMATION,
                                user, NULL, acl, NULL);
    LocalFree(acl);
  }
  caml_stat_free(p);
  if (err != ERROR_SUCCESS) win_fail(err, "make_private", path);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_clone(value src, value dst) {
  CAMLparam2(src, dst);
  errno = EOPNOTSUPP;
  uerror("clone", dst);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_is_network_fs(value path) {
  CAMLparam1(path);
  wchar_t *p = wide_path(path);
  wchar_t root[MAX_PATH + 1];
  BOOL ok = GetVolumePathNameW(p, root, MAX_PATH + 1);
  DWORD err = ok ? 0 : GetLastError();
  caml_stat_free(p);
  if (!ok) win_fail(err, "statfs", path);
  CAMLreturn(Val_bool(GetDriveTypeW(root) == DRIVE_REMOTE));
}

CAMLprim value tsync_is_macos(value unit) { return Val_false; }

CAMLprim value tsync_memory_split(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(res);
  res = caml_alloc_tuple(2);
  Store_field(res, 0, Val_long(-1));
  Store_field(res, 1, Val_long(-1));
  CAMLreturn(res);
}

CAMLprim value tsync_malloc_trim(value unit) {
  _heapmin();
  return Val_unit;
}

/* No watch here: its only consumer, the local store, is refused on Windows
   (cloud-files §2), so the consumer polls as on macOS. */
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

CAMLprim value tsync_terminal_columns(value fd) {
  CONSOLE_SCREEN_BUFFER_INFO info;
  if (Descr_kind_val(fd) != KIND_HANDLE || !GetConsoleScreenBufferInfo(Handle_val(fd), &info))
    return Val_int(0);
  return Val_int(info.srWindow.Right - info.srWindow.Left + 1);
}

CAMLprim value tsync_drop_mapped_pages(value v) { return Val_unit; }

/* Seconds on a clock that counts time spent asleep (publication A7). */
CAMLprim value tsync_boottime(value unit) {
  return caml_copy_double((double)GetTickCount64() / 1000.0);
}

#else

#include <fcntl.h>
#include <signal.h>
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

CAMLprim value tsync_end_with_this_process(value pid) { return Val_unit; }

CAMLprim value tsync_unlink(value path) {
  CAMLparam1(path);
  char *p = caml_stat_strdup(String_val(path));
  int r;
  caml_release_runtime_system();
  do { r = unlink(p); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(p);
  if (r < 0) { errno = e; uerror("unlink", path); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_session_event(value unit) {
  CAMLparam1(unit);
  errno = ENOSYS;
  uerror("session", Nothing);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_is_private(value path) {
  CAMLparam1(path);
  struct stat s;
  if (lstat(String_val(path), &s) < 0) uerror("lstat", path);
  CAMLreturn(Val_bool(s.st_uid == getuid() && (s.st_mode & 077) == 0));
}

CAMLprim value tsync_owned_by_this_user(value path) {
  CAMLparam1(path);
  struct stat s;
  if (lstat(String_val(path), &s) < 0) uerror("lstat", path);
  CAMLreturn(Val_bool(s.st_uid == getuid()));
}

CAMLprim value tsync_make_private(value path) {
  CAMLparam1(path);
  struct stat s;
  if (lstat(String_val(path), &s) < 0) uerror("lstat", path);
  if (chmod(String_val(path), S_ISDIR(s.st_mode) ? 0700 : 0600) < 0) uerror("chmod", path);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_rename(value src, value dst) {
  CAMLparam2(src, dst);
  char *s = caml_stat_strdup(String_val(src)), *d = caml_stat_strdup(String_val(dst));
  int r;
  caml_release_runtime_system();
  do { r = rename(s, d); } while (r < 0 && errno == EINTR);
  int e = errno;
  caml_acquire_runtime_system();
  caml_stat_free(s);
  caml_stat_free(d);
  if (r < 0) { errno = e; uerror("rename", src); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_system_random(value len) {
  CAMLparam1(len);
  CAMLlocal1(res);
  size_t wanted = Long_val(len), got = 0;
  res = caml_alloc_string(wanted);
  int fd;
  do { fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC); } while (fd < 0 && errno == EINTR);
  if (fd < 0) uerror("open", Nothing);
  while (got < wanted) {
    ssize_t r = read(fd, (char *)Bytes_val(res) + got, wanted - got);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) {
      int e = r < 0 ? errno : EIO;
      close(fd);
      errno = e;
      uerror("read", Nothing);
    }
    got += r;
  }
  close(fd);
  CAMLreturn(res);
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
  /* Bionic declares syncfs from API 28 only; the kernel has always had it. */
  int r = syscall(SYS_syncfs, Int_val(fd)), e = errno;
  caml_acquire_runtime_system();
  if (r < 0) { errno = e; uerror("syncfs", Nothing); }
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_peer_same_user(value fd) {
  CAMLparam1(fd);
  struct ucred c;
  socklen_t l = sizeof(c);
  if (getsockopt(Int_val(fd), SOL_SOCKET, SO_PEERCRED, &c, &l) < 0) uerror("getsockopt", Nothing);
  CAMLreturn(Val_bool(c.uid == getuid()));
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
  case 0x5346414F: /* OpenAFS */
  case 0x01021997: /* 9P */
  case 0x00C36400: /* CEPH */
  case 0x0BD00BD0: /* Lustre */
  case 0x01161970: /* GFS2 */
  case 0x7461636F: /* OCFS2 */
  case 0x73757245: /* CODA */
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
#ifndef __ANDROID__
  malloc_trim(0);
#endif
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

CAMLprim value tsync_peer_same_user(value fd) {
  CAMLparam1(fd);
  uid_t u;
  gid_t g;
  if (getpeereid(Int_val(fd), &u, &g) < 0) uerror("getpeereid", Nothing);
  CAMLreturn(Val_bool(u == getuid()));
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

/* Seconds on a clock that counts time spent suspended (publication A7). */
CAMLprim value tsync_boottime(value unit) {
  struct timespec ts;
#if defined(__linux__)
  clock_gettime(CLOCK_BOOTTIME, &ts);
#else
  clock_gettime(CLOCK_MONOTONIC, &ts);
#endif
  return caml_copy_double((double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
}

#endif
