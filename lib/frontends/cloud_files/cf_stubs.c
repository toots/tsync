/* The Cloud Filter connection (cloud-files §9.1, §13): callbacks arrive on the
   system's threads, each copied into an OCaml request and handed to the
   closure registered as "tsync_cf_callback", which completes it through the
   operations below before it returns. */

#define CAML_NAME_SPACE
#include <stdio.h>
#include <string.h>
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "cf_api.h"
#include "cf_strings.h"

static CfConnectSyncRoot_t cf_connect;
static CfDisconnectSyncRoot_t cf_disconnect;
static CfExecute_t cf_execute;
static CfGetPlaceholderInfo_t cf_get_placeholder_info;
static CfHydratePlaceholder_t cf_hydrate;
static CfConvertToPlaceholder_t cf_convert;
static CfUpdatePlaceholder_t cf_update;

static void fail_hresult(const char *what, HRESULT hr) {
  char message[128];
  snprintf(message, sizeof message, "%s: HRESULT 0x%08lx", what,
           (unsigned long)hr);
  caml_failwith(message);
}

static void load_api(void) {
  if (cf_execute != NULL)
    return;
  HMODULE library = LoadLibraryW(L"cldapi.dll");
  if (library == NULL)
    caml_failwith("cldapi.dll cannot be loaded: Windows 10 1709 or later is needed");
  cf_connect = (CfConnectSyncRoot_t)GetProcAddress(library, "CfConnectSyncRoot");
  cf_disconnect = (CfDisconnectSyncRoot_t)GetProcAddress(library, "CfDisconnectSyncRoot");
  cf_execute = (CfExecute_t)GetProcAddress(library, "CfExecute");
  cf_get_placeholder_info =
      (CfGetPlaceholderInfo_t)GetProcAddress(library, "CfGetPlaceholderInfo");
  cf_hydrate = (CfHydratePlaceholder_t)GetProcAddress(library, "CfHydratePlaceholder");
  cf_convert = (CfConvertToPlaceholder_t)GetProcAddress(library, "CfConvertToPlaceholder");
  cf_update = (CfUpdatePlaceholder_t)GetProcAddress(library, "CfUpdatePlaceholder");
  if (cf_connect == NULL || cf_disconnect == NULL || cf_execute == NULL ||
      cf_get_placeholder_info == NULL || cf_hydrate == NULL || cf_convert == NULL ||
      cf_update == NULL)
    caml_failwith("cldapi.dll lacks a function the provider calls");
}

/* A system thread the runtime has registered owes an unregistration when it
   ends, which the fiber-local slot's destructor runs. */
static DWORD registered_slot = FLS_OUT_OF_INDEXES;

static void WINAPI thread_ends(void *registered) {
  if (registered != NULL)
    caml_c_thread_unregister();
}

static void enter_ocaml(void) {
  if (FlsGetValue(registered_slot) == NULL) {
    if (!caml_c_thread_register())
      abort();
    FlsSetValue(registered_slot, (void *)1);
  }
  caml_acquire_runtime_system();
}

static value int64_value(LONGLONG n) { return caml_copy_int64(n); }

/* With CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH a path is the volume's: the
   drive name makes it one the file API opens. */
static value full_path(const CF_CALLBACK_INFO *info, const wchar_t *relative) {
  if (relative == NULL)
    return caml_copy_string("");
  size_t volume = info->VolumeDosName == NULL ? 0 : wcslen(info->VolumeDosName);
  size_t rest = wcslen(relative);
  wchar_t *path = malloc((volume + rest + 1) * sizeof(wchar_t));
  if (path == NULL)
    caml_raise_out_of_memory();
  if (volume > 0)
    memcpy(path, info->VolumeDosName, volume * sizeof(wchar_t));
  if (rest > 0)
    memcpy(path + volume, relative, rest * sizeof(wchar_t));
  path[volume + rest] = 0;
  value _path = value_of_utf16(path);
  free(path);
  return _path;
}

/* The fields of Cloud_files_api.request, in order. */
static value request_of(const CF_CALLBACK_INFO *info,
                        const CF_CALLBACK_PARAMETERS *p, LONG kind) {
  CAMLparam0();
  CAMLlocal5(_request, _identity, _path, _target, _transfer);
  CAMLlocal1(_request_key);
  LONGLONG offset = 0, length = 0, optional_offset = 0, optional_length = 0;
  LONG flags = 0;
  const wchar_t *target = NULL;
  switch (kind) {
  case CF_CALLBACK_TYPE_FETCH_DATA:
    flags = p->FetchData.Flags;
    offset = p->FetchData.RequiredFileOffset;
    length = p->FetchData.RequiredLength;
    optional_offset = p->FetchData.OptionalFileOffset;
    optional_length = p->FetchData.OptionalLength;
    break;
  case CF_CALLBACK_TYPE_CANCEL_FETCH_DATA:
    flags = p->Cancel.Flags;
    offset = p->Cancel.FetchData.FileOffset;
    length = p->Cancel.FetchData.Length;
    break;
  case CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS:
    flags = p->FetchPlaceholders.Flags;
    break;
  case CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION:
    flags = p->CloseCompletion.Flags;
    break;
  case CF_CALLBACK_TYPE_NOTIFY_DEHYDRATE:
    flags = p->Dehydrate.Flags;
    break;
  case CF_CALLBACK_TYPE_NOTIFY_DELETE:
    flags = p->Delete.Flags;
    break;
  case CF_CALLBACK_TYPE_NOTIFY_RENAME:
    flags = p->Rename.Flags;
    target = p->Rename.TargetPath;
    break;
  }
  _identity = caml_alloc_initialized_string(info->FileIdentityLength,
                                            (const char *)info->FileIdentity);
  _path = full_path(info, info->NormalizedPath);
  _target = full_path(info, target);
  _transfer = int64_value(info->TransferKey);
  _request_key = int64_value(info->RequestKey);
  _request = caml_alloc_tuple(13);
  Store_field(_request, 0, Val_long(kind));
  Store_field(_request, 1, _transfer);
  Store_field(_request, 2, _request_key);
  Store_field(_request, 3, _identity);
  Store_field(_request, 4, _path);
  Store_field(_request, 5, Val_long(info->FileSize));
  Store_field(_request, 6,
              Val_long(info->ProcessInfo == NULL ? 0 : info->ProcessInfo->ProcessId));
  Store_field(_request, 7, Val_long(flags));
  Store_field(_request, 8, Val_long(offset));
  Store_field(_request, 9, Val_long(length));
  Store_field(_request, 10, Val_long(optional_offset));
  Store_field(_request, 11, Val_long(optional_length));
  Store_field(_request, 12, _target);
  CAMLreturn(_request);
}

/* The closure handles every request it is given; an exception escaping it is
   a defect, logged by the closure itself, and leaves the request to time out. */
static void CALLBACK on_callback(const CF_CALLBACK_INFO *info,
                                 const CF_CALLBACK_PARAMETERS *parameters,
                                 LONG kind) {
  enter_ocaml();
  {
    CAMLparam0();
    CAMLlocal1(_request);
    const value *closure = caml_named_value("tsync_cf_callback");
    if (closure != NULL) {
      _request = request_of(info, parameters, kind);
      caml_callback_exn(*closure, _request);
    }
    CAMLdrop;
  }
  caml_release_runtime_system();
}

#define CALLBACK_OF(kind, name)                                                \
  static void CALLBACK name(const CF_CALLBACK_INFO *info,                      \
                            const CF_CALLBACK_PARAMETERS *parameters) {        \
    on_callback(info, parameters, kind);                                       \
  }

CALLBACK_OF(CF_CALLBACK_TYPE_FETCH_DATA, on_fetch_data)
CALLBACK_OF(CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, on_cancel_fetch_data)
CALLBACK_OF(CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS, on_fetch_placeholders)
CALLBACK_OF(CF_CALLBACK_TYPE_CANCEL_FETCH_PLACEHOLDERS, on_cancel_fetch_placeholders)
CALLBACK_OF(CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION, on_close_completion)
CALLBACK_OF(CF_CALLBACK_TYPE_NOTIFY_DEHYDRATE, on_dehydrate)
CALLBACK_OF(CF_CALLBACK_TYPE_NOTIFY_DELETE, on_delete)
CALLBACK_OF(CF_CALLBACK_TYPE_NOTIFY_RENAME, on_rename)

static const CF_CALLBACK_REGISTRATION callbacks[] = {
    {CF_CALLBACK_TYPE_FETCH_DATA, on_fetch_data},
    {CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, on_cancel_fetch_data},
    {CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS, on_fetch_placeholders},
    {CF_CALLBACK_TYPE_CANCEL_FETCH_PLACEHOLDERS, on_cancel_fetch_placeholders},
    {CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION, on_close_completion},
    {CF_CALLBACK_TYPE_NOTIFY_DEHYDRATE, on_dehydrate},
    {CF_CALLBACK_TYPE_NOTIFY_DELETE, on_delete},
    {CF_CALLBACK_TYPE_NOTIFY_RENAME, on_rename},
    {CF_CALLBACK_TYPE_NONE, NULL}};

CAMLprim value tsync_cf_connect(value _path) {
  CAMLparam1(_path);
  load_api();
  if (registered_slot == FLS_OUT_OF_INDEXES) {
    registered_slot = FlsAlloc(thread_ends);
    if (registered_slot == FLS_OUT_OF_INDEXES)
      caml_failwith("no fiber-local slot for the callback threads");
  }
  wchar_t *path = utf16_of_value(_path);
  CF_CONNECTION_KEY key = 0;
  caml_release_runtime_system();
  HRESULT hr = cf_connect(path, callbacks, NULL,
                          CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO |
                              CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
                          &key);
  caml_acquire_runtime_system();
  free(path);
  if (FAILED(hr))
    fail_hresult("connecting the sync root", hr);
  CAMLreturn(caml_copy_int64(key));
}

CAMLprim value tsync_cf_disconnect(value _key) {
  CAMLparam1(_key);
  CF_CONNECTION_KEY key = Int64_val(_key);
  caml_release_runtime_system();
  HRESULT hr = cf_disconnect(key);
  caml_acquire_runtime_system();
  if (FAILED(hr))
    fail_hresult("disconnecting the sync root", hr);
  CAMLreturn(Val_unit);
}

static CF_OPERATION_INFO operation(value _key, value _transfer, value _request,
                                   LONG type) {
  CF_OPERATION_INFO op = {0};
  op.StructSize = sizeof op;
  op.Type = type;
  op.ConnectionKey = Int64_val(_key);
  op.TransferKey = Int64_val(_transfer);
  op.RequestKey = Int64_val(_request);
  return op;
}

static void execute(CF_OPERATION_INFO *op, CF_OPERATION_PARAMETERS *params,
                    const char *what) {
  load_api();
  caml_release_runtime_system();
  HRESULT hr = cf_execute(op, params);
  caml_acquire_runtime_system();
  if (FAILED(hr))
    fail_hresult(what, hr);
}

/* [kind]: 0 delete, 1 rename, 2 dehydrate. */
CAMLprim value tsync_cf_ack(value _key, value _transfer, value _request,
                            value _kind, value _status) {
  CAMLparam5(_key, _transfer, _request, _kind, _status);
  static const LONG types[] = {CF_OPERATION_TYPE_ACK_DELETE,
                               CF_OPERATION_TYPE_ACK_RENAME,
                               CF_OPERATION_TYPE_ACK_DEHYDRATE};
  CF_OPERATION_INFO op = operation(_key, _transfer, _request, types[Int_val(_kind)]);
  CF_OPERATION_PARAMETERS params = {0};
  switch (Int_val(_kind)) {
  case 0:
    params.ParamSize = CF_SIZE_OF_OP_PARAM(AckDelete);
    params.AckDelete.CompletionStatus = Int32_val(_status);
    break;
  case 1:
    params.ParamSize = CF_SIZE_OF_OP_PARAM(AckRename);
    params.AckRename.CompletionStatus = Int32_val(_status);
    break;
  default:
    params.ParamSize = CF_SIZE_OF_OP_PARAM(AckDehydrate);
    params.AckDehydrate.CompletionStatus = Int32_val(_status);
    break;
  }
  execute(&op, &params, "acknowledging a callback");
  CAMLreturn(Val_unit);
}

/* Unix seconds as the 100 ns intervals since 1601 Windows counts. */
static LONGLONG file_time(double seconds) {
  return (LONGLONG)((seconds + 11644473600.0) * 10000000.0);
}

/* [_entries]: an array of (name, is_dir, size, mtime, identity, read_only). */
CAMLprim value tsync_cf_transfer_placeholders(value _key, value _transfer,
                                              value _request, value _status,
                                              value _entries) {
  CAMLparam5(_key, _transfer, _request, _status, _entries);
  load_api();
  mlsize_t count = Wosize_val(_entries);
  CF_PLACEHOLDER_CREATE_INFO *placeholders =
      calloc(count == 0 ? 1 : count, sizeof *placeholders);
  wchar_t **names = calloc(count == 0 ? 1 : count, sizeof *names);
  char **identities = calloc(count == 0 ? 1 : count, sizeof *identities);
  if (placeholders == NULL || names == NULL || identities == NULL)
    caml_raise_out_of_memory();
  for (mlsize_t i = 0; i < count; i++) {
    value _e = Field(_entries, i);
    CF_PLACEHOLDER_CREATE_INFO *ph = &placeholders[i];
    LONGLONG when = file_time(Double_val(Field(_e, 3)));
    names[i] = utf16_of_value(Field(_e, 0));
    mlsize_t identity_length = caml_string_length(Field(_e, 4));
    identities[i] = malloc(identity_length == 0 ? 1 : identity_length);
    if (identities[i] == NULL)
      caml_raise_out_of_memory();
    memcpy(identities[i], String_val(Field(_e, 4)), identity_length);
    ph->RelativeFileName = names[i];
    ph->FileIdentity = identities[i];
    ph->FileIdentityLength = (DWORD)identity_length;
    ph->Flags = CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;
    ph->FsMetadata.BasicInfo.CreationTime.QuadPart = when;
    ph->FsMetadata.BasicInfo.LastWriteTime.QuadPart = when;
    ph->FsMetadata.BasicInfo.LastAccessTime.QuadPart = when;
    ph->FsMetadata.BasicInfo.ChangeTime.QuadPart = when;
    ph->FsMetadata.BasicInfo.FileAttributes =
        (Bool_val(Field(_e, 1)) ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL) |
        (Bool_val(Field(_e, 5)) ? FILE_ATTRIBUTE_READONLY : 0);
    ph->FsMetadata.FileSize.QuadPart =
        Bool_val(Field(_e, 1)) ? 0 : (LONGLONG)Long_val(Field(_e, 2));
  }
  CF_OPERATION_INFO op =
      operation(_key, _transfer, _request, CF_OPERATION_TYPE_TRANSFER_PLACEHOLDERS);
  CF_OPERATION_PARAMETERS params = {0};
  params.ParamSize = CF_SIZE_OF_OP_PARAM(TransferPlaceholders);
  params.TransferPlaceholders.Flags =
      CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_DISABLE_ON_DEMAND_POPULATION;
  params.TransferPlaceholders.CompletionStatus = Int32_val(_status);
  params.TransferPlaceholders.PlaceholderTotalCount = (LONGLONG)count;
  params.TransferPlaceholders.PlaceholderArray = count == 0 ? NULL : placeholders;
  params.TransferPlaceholders.PlaceholderCount = (DWORD)count;
  caml_release_runtime_system();
  HRESULT hr = cf_execute(&op, &params);
  caml_acquire_runtime_system();
  for (mlsize_t i = 0; i < count; i++) {
    free(names[i]);
    free(identities[i]);
  }
  free(names);
  free(identities);
  free(placeholders);
  if (FAILED(hr))
    fail_hresult("transferring placeholders", hr);
  CAMLreturn(Val_unit);
}

/* [_buffer] holds [length] bytes for the file at [offset]; it is read only
   while the runtime lock is released, so it must not move: a bigarray. */
CAMLprim value tsync_cf_transfer_data_native(value _key, value _transfer,
                                             value _request, value _status,
                                             value _buffer, value _offset,
                                             value _length) {
  CAMLparam5(_key, _transfer, _request, _status, _buffer);
  CAMLxparam2(_offset, _length);
  CF_OPERATION_INFO op =
      operation(_key, _transfer, _request, CF_OPERATION_TYPE_TRANSFER_DATA);
  CF_OPERATION_PARAMETERS params = {0};
  params.ParamSize = CF_SIZE_OF_OP_PARAM(TransferData);
  params.TransferData.CompletionStatus = Int32_val(_status);
  params.TransferData.Buffer = Caml_ba_data_val(_buffer);
  params.TransferData.Offset = Long_val(_offset);
  params.TransferData.Length = Long_val(_length);
  execute(&op, &params, "transferring data");
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_cf_transfer_data_bytecode(value *argv, int argn) {
  (void)argn;
  return tsync_cf_transfer_data_native(argv[0], argv[1], argv[2], argv[3],
                                       argv[4], argv[5], argv[6]);
}

/* A name as NTFS compares it: uppercased code unit by code unit, which is what
   the invariant locale's simple mapping does (cloud-files §7.2). */
CAMLprim value tsync_cf_upcase(value _name) {
  CAMLparam1(_name);
  CAMLlocal1(_upper);
  wchar_t *name = utf16_of_value(_name);
  int units = (int)wcslen(name);
  if (units > 0)
    LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, name, units, name,
                  units, NULL, NULL, 0);
  _upper = value_of_utf16_length(name, units);
  free(name);
  CAMLreturn(_upper);
}

static HANDLE open_placeholder(value _path, DWORD access) {
  wchar_t *path = utf16_of_value(_path);
  caml_release_runtime_system();
  HANDLE h = CreateFileW(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  caml_acquire_runtime_system();
  free(path);
  return h;
}

/* The placeholder's file identity, or [None] for a file or folder that is not
   a placeholder (cloud-files §8.1). */
CAMLprim value tsync_cf_identity(value _path) {
  CAMLparam1(_path);
  CAMLlocal1(_identity);
  load_api();
  HANDLE h = open_placeholder(_path, FILE_READ_ATTRIBUTES);
  if (h == INVALID_HANDLE_VALUE)
    caml_failwith("the item cannot be opened for its placeholder state");
  DWORD size = sizeof(CF_PLACEHOLDER_BASIC_INFO) + 4096, written = 0;
  CF_PLACEHOLDER_BASIC_INFO *info = malloc(size);
  if (info == NULL) {
    CloseHandle(h);
    caml_raise_out_of_memory();
  }
  caml_release_runtime_system();
  HRESULT hr = cf_get_placeholder_info(h, CF_PLACEHOLDER_INFO_BASIC, info, size, &written);
  caml_acquire_runtime_system();
  CloseHandle(h);
  if (FAILED(hr)) {
    free(info);
    CAMLreturn(Val_none);
  }
  _identity = caml_alloc_initialized_string(info->FileIdentityLength,
                                            (const char *)info->FileIdentity);
  free(info);
  CAMLreturn(caml_alloc_some(_identity));
}

/* Makes the file's whole content local, through this provider's own fetch
   callbacks, which run on other threads (cloud-files §9.2). */
CAMLprim value tsync_cf_hydrate(value _path) {
  CAMLparam1(_path);
  load_api();
  HANDLE h = open_placeholder(_path, GENERIC_READ);
  if (h == INVALID_HANDLE_VALUE)
    caml_failwith("the file cannot be opened to make its content whole");
  caml_release_runtime_system();
  HRESULT hr = cf_hydrate(h, 0, -1, 0, NULL);
  caml_acquire_runtime_system();
  CloseHandle(h);
  if (FAILED(hr))
    fail_hresult("making the content whole", hr);
  CAMLreturn(Val_unit);
}

#include <winioctl.h>

/* The recursive change watch (cloud-files §9.4). The handle is an int64 so
   OCaml can hold it; reads block their thread only. */
CAMLprim value tsync_cf_watch_open(value _path) {
  CAMLparam1(_path);
  wchar_t *path = utf16_of_value(_path);
  HANDLE h = CreateFileW(path, FILE_LIST_DIRECTORY,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                         OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  free(path);
  if (h == INVALID_HANDLE_VALUE)
    caml_failwith("the sync root cannot be watched");
  CAMLreturn(caml_copy_int64((int64_t)(intptr_t)h));
}

CAMLprim value tsync_cf_watch_close(value _handle) {
  CloseHandle((HANDLE)(intptr_t)Int64_val(_handle));
  return Val_unit;
}

/* [Some] list of (action, relative path), or [None] when events were lost: an
   overflow, which the caller answers with a sweep. */
CAMLprim value tsync_cf_watch_read(value _handle) {
  CAMLparam1(_handle);
  CAMLlocal4(_list, _cell, _event, _name);
  HANDLE h = (HANDLE)(intptr_t)Int64_val(_handle);
  DWORD size = 64 * 1024, returned = 0;
  BYTE *buffer = malloc(size);
  if (buffer == NULL)
    caml_raise_out_of_memory();
  caml_release_runtime_system();
  BOOL ok = ReadDirectoryChangesW(
      h, buffer, size, TRUE,
      FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
          FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
          FILE_NOTIFY_CHANGE_LAST_WRITE,
      &returned, NULL, NULL);
  DWORD error = GetLastError();
  caml_acquire_runtime_system();
  if (!ok && error != ERROR_NOTIFY_ENUM_DIR) {
    free(buffer);
    caml_failwith("the sync root's watch failed");
  }
  if (!ok || returned == 0) {
    free(buffer);
    CAMLreturn(Val_none);
  }
  _list = Val_emptylist;
  for (BYTE *at = buffer;;) {
    FILE_NOTIFY_INFORMATION *n = (FILE_NOTIFY_INFORMATION *)at;
    _name = value_of_utf16_length(n->FileName, (int)(n->FileNameLength / sizeof(WCHAR)));
    _event = caml_alloc_tuple(2);
    Store_field(_event, 0, Val_long(n->Action));
    Store_field(_event, 1, _name);
    _cell = caml_alloc_small(2, 0);
    Field(_cell, 0) = _event;
    Field(_cell, 1) = _list;
    _list = _cell;
    if (n->NextEntryOffset == 0)
      break;
    at += n->NextEntryOffset;
  }
  free(buffer);
  CAMLreturn(caml_alloc_some(_list));
}

static HANDLE open_item(const wchar_t *path, DWORD access, DWORD share) {
  return CreateFileW(path, access, share, NULL, OPEN_EXISTING,
                     FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
}

static LONGLONG usn_of(HANDLE h) {
  BYTE record[1024];
  DWORD returned = 0;
  if (!DeviceIoControl(h, FSCTL_READ_FILE_USN_DATA, NULL, 0, record, sizeof record,
                       &returned, NULL))
    return -1;
  return ((USN_RECORD *)record)->Usn;
}

#define CLOUD_TAG_MASK 0xFFFF0FFFu
#define CLOUD_TAG 0x9000001Au

/* An item as the take reads it (cloud-files §9.3): the fields of
   Cf.state, in order, or [None] when it is gone. */
CAMLprim value tsync_cf_state(value _path) {
  CAMLparam1(_path);
  CAMLlocal3(_state, _identity, _usn);
  load_api();
  wchar_t *path = utf16_of_value(_path);
  caml_release_runtime_system();
  HANDLE h = open_item(path, FILE_READ_ATTRIBUTES,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
  FILE_ATTRIBUTE_TAG_INFO tag = {0};
  BOOL have_tag = h != INVALID_HANDLE_VALUE &&
                  GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, sizeof tag);
  DWORD size = sizeof(CF_PLACEHOLDER_BASIC_INFO) + 4096, written = 0;
  CF_PLACEHOLDER_BASIC_INFO *info = calloc(1, size);
  BOOL placeholder = have_tag && info != NULL &&
                     (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
                     (tag.ReparseTag & CLOUD_TAG_MASK) == CLOUD_TAG &&
                     SUCCEEDED(cf_get_placeholder_info(h, CF_PLACEHOLDER_INFO_BASIC, info,
                                                       size, &written));
  LONGLONG usn = have_tag ? usn_of(h) : -1;
  if (h != INVALID_HANDLE_VALUE)
    CloseHandle(h);
  caml_acquire_runtime_system();
  free(path);
  if (!have_tag) {
    free(info);
    CAMLreturn(Val_none);
  }
  BOOL other_reparse = (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
                       (tag.ReparseTag & CLOUD_TAG_MASK) != CLOUD_TAG;
  _identity = placeholder ? caml_alloc_initialized_string(info->FileIdentityLength,
                                                          (const char *)info->FileIdentity)
                          : caml_copy_string("");
  _usn = caml_copy_int64(usn);
  _state = caml_alloc_tuple(7);
  Store_field(_state, 0, Val_bool(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY));
  Store_field(_state, 1, Val_bool(other_reparse));
  Store_field(_state, 2, Val_bool(placeholder));
  Store_field(_state, 3, Val_bool(placeholder && info->InSyncState == 1));
  Store_field(_state, 4, _identity);
  Store_field(_state, 5, _usn);
  /* FILE_ATTRIBUTE_RECALL_ON_OPEN: a folder whose children were never asked. */
  Store_field(_state, 6, Val_bool(tag.FileAttributes & 0x40000));
  free(info);
  CAMLreturn(caml_alloc_some(_state));
}

/* A handle that denies writing to others, through which the take converts or
   updates the item; [None] while a writer holds it (cloud-files §9.3). */
CAMLprim value tsync_cf_hold(value _path) {
  CAMLparam1(_path);
  wchar_t *path = utf16_of_value(_path);
  caml_release_runtime_system();
  HANDLE h = open_item(path, FILE_READ_ATTRIBUTES | WRITE_DAC | SYNCHRONIZE,
                       FILE_SHARE_READ | FILE_SHARE_DELETE);
  caml_acquire_runtime_system();
  free(path);
  if (h == INVALID_HANDLE_VALUE)
    CAMLreturn(Val_none);
  CAMLreturn(caml_alloc_some(caml_copy_int64((int64_t)(intptr_t)h)));
}

CAMLprim value tsync_cf_held_usn(value _handle) {
  return caml_copy_int64(usn_of((HANDLE)(intptr_t)Int64_val(_handle)));
}

CAMLprim value tsync_cf_release(value _handle) {
  CloseHandle((HANDLE)(intptr_t)Int64_val(_handle));
  return Val_unit;
}

/* Stores an identity on a held item, converting it to a placeholder when it is
   not one; [in_sync] marks it so. */
CAMLprim value tsync_cf_set_identity(value _handle, value _placeholder, value _identity,
                                     value _in_sync) {
  CAMLparam4(_handle, _placeholder, _identity, _in_sync);
  load_api();
  HANDLE h = (HANDLE)(intptr_t)Int64_val(_handle);
  DWORD length = (DWORD)caml_string_length(_identity);
  void *identity = malloc(length == 0 ? 1 : length);
  if (identity == NULL)
    caml_raise_out_of_memory();
  memcpy(identity, String_val(_identity), length);
  BOOL in_sync = Bool_val(_in_sync), placeholder = Bool_val(_placeholder);
  caml_release_runtime_system();
  HRESULT hr =
      placeholder
          ? cf_update(h, NULL, identity, length, NULL, 0,
                      in_sync ? CF_UPDATE_FLAG_MARK_IN_SYNC : 0, NULL, NULL)
          : cf_convert(h, identity, length, in_sync ? CF_CONVERT_FLAG_MARK_IN_SYNC : 0,
                       NULL, NULL);
  caml_acquire_runtime_system();
  free(identity);
  if (FAILED(hr))
    fail_hresult(placeholder ? "updating the placeholder" : "converting to a placeholder", hr);
  CAMLreturn(Val_unit);
}
