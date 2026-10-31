/* Sync root registration through the storage provider API (cloud-files §8.3,
   §13.1), which needs the package identity tsyncd.exe carries. The WinRT
   interfaces are declared here, slot by slot, from Microsoft's API metadata as
   the windows 0.58 crate renders it (MIT or Apache-2.0). */

#define CAML_NAME_SPACE
#include <stdio.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <windows.h>
#include <inspectable.h>
#include <roapi.h>
#include <winstring.h>
#include <asyncinfo.h>
#include <sddl.h>

#include "cf_strings.h"

typedef struct inspectable_vtbl {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(void *, REFIID, void **);
  ULONG(STDMETHODCALLTYPE *AddRef)(void *);
  ULONG(STDMETHODCALLTYPE *Release)(void *);
  HRESULT(STDMETHODCALLTYPE *GetIids)(void *, ULONG *, IID **);
  HRESULT(STDMETHODCALLTYPE *GetRuntimeClassName)(void *, HSTRING *);
  HRESULT(STDMETHODCALLTYPE *GetTrustLevel)(void *, int *);
} inspectable_vtbl;

typedef struct folder_statics_vtbl {
  inspectable_vtbl base;
  HRESULT(STDMETHODCALLTYPE *GetFolderFromPathAsync)(void *, HSTRING, void **);
} folder_statics_vtbl;

typedef struct async_folder_vtbl {
  inspectable_vtbl base;
  HRESULT(STDMETHODCALLTYPE *put_Completed)(void *, void *);
  HRESULT(STDMETHODCALLTYPE *get_Completed)(void *, void **);
  HRESULT(STDMETHODCALLTYPE *GetResults)(void *, void **);
} async_folder_vtbl;

typedef HRESULT(STDMETHODCALLTYPE *put_hstring)(void *, HSTRING);
typedef HRESULT(STDMETHODCALLTYPE *put_unknown)(void *, void *);
typedef HRESULT(STDMETHODCALLTYPE *put_uint)(void *, UINT32);
typedef HRESULT(STDMETHODCALLTYPE *put_bool)(void *, boolean);
typedef HRESULT(STDMETHODCALLTYPE *getter)(void *, void *);

typedef struct sync_root_info_vtbl {
  inspectable_vtbl base;
  getter get_Id;
  put_hstring put_Id;
  getter get_Context;
  put_unknown put_Context;
  getter get_Path;
  put_unknown put_Path;
  getter get_DisplayNameResource;
  put_hstring put_DisplayNameResource;
  getter get_IconResource;
  put_hstring put_IconResource;
  getter get_HydrationPolicy;
  put_uint put_HydrationPolicy;
  getter get_HydrationPolicyModifier;
  put_uint put_HydrationPolicyModifier;
  getter get_PopulationPolicy;
  put_uint put_PopulationPolicy;
  getter get_InSyncPolicy;
  put_uint put_InSyncPolicy;
  getter get_HardlinkPolicy;
  put_uint put_HardlinkPolicy;
  getter get_ShowSiblingsAsGroup;
  put_bool put_ShowSiblingsAsGroup;
  getter get_Version;
  put_hstring put_Version;
  getter get_ProtectionMode;
  put_uint put_ProtectionMode;
  getter get_AllowPinning;
  put_bool put_AllowPinning;
} sync_root_info_vtbl;

typedef struct sync_root_manager_vtbl {
  inspectable_vtbl base;
  HRESULT(STDMETHODCALLTYPE *Register)(void *, void *);
  HRESULT(STDMETHODCALLTYPE *Unregister)(void *, HSTRING);
  HRESULT(STDMETHODCALLTYPE *GetSyncRootInformationForFolder)(void *, void *, void **);
  HRESULT(STDMETHODCALLTYPE *GetSyncRootInformationForId)(void *, HSTRING, void **);
  HRESULT(STDMETHODCALLTYPE *GetCurrentSyncRoots)(void *, void **);
} sync_root_manager_vtbl;

typedef struct vector_view_vtbl {
  inspectable_vtbl base;
  HRESULT(STDMETHODCALLTYPE *GetAt)(void *, UINT32, void **);
  HRESULT(STDMETHODCALLTYPE *get_Size)(void *, UINT32 *);
} vector_view_vtbl;

typedef struct storage_item_vtbl {
  inspectable_vtbl base;
  void *RenameAsyncOverloadDefaultOptions, *RenameAsync, *DeleteAsyncOverloadDefaultOptions,
      *DeleteAsync, *GetBasicPropertiesAsync, *get_Name;
  HRESULT(STDMETHODCALLTYPE *get_Path)(void *, HSTRING *);
} storage_item_vtbl;

typedef struct com_object {
  const void *vtbl;
} com_object;

#define VTBL(type, object) ((const type *)((com_object *)(object))->vtbl)

static const IID iid_folder_statics = {
    0x08f327ff, 0x85d5, 0x48b9, {0xae, 0xe9, 0x28, 0x51, 0x1e, 0x33, 0x9f, 0x9f}};
static const IID iid_sync_root_info = {
    0x7c1305c4, 0x99f9, 0x41ac, {0x89, 0x04, 0xab, 0x05, 0x5d, 0x65, 0x49, 0x26}};
static const IID iid_sync_root_manager = {
    0x3e99fbbf, 0x8fe3, 0x4b40, {0xab, 0xc7, 0xf6, 0xfc, 0x3d, 0x74, 0xc9, 0x8e}};
static const IID iid_storage_item = {
    0x4207a996, 0xca2f, 0x42f7, {0xbd, 0xe8, 0x8b, 0x10, 0x45, 0x7a, 0x7f, 0x30}};
static const IID iid_async_info = {
    0x00000036, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

/* StorageProviderHydrationPolicy, …Modifier, …PopulationPolicy,
   …InSyncPolicy, …HardlinkPolicy and …ProtectionMode values (§8.3). */
enum {
  HYDRATION_PROGRESSIVE = 1,
  HYDRATION_AUTO_DEHYDRATION_ALLOWED = 4,
  POPULATION_FULL = 1,
  IN_SYNC_FILE_LAST_WRITE_TIME = 256,
  IN_SYNC_PRESERVE_FOR_SYNC_ENGINE = 0x80000000u,
  HARDLINK_NONE = 0,
  PROTECTION_PERSONAL = 1
};

static void release(void *object) {
  if (object != NULL)
    VTBL(inspectable_vtbl, object)->Release(object);
}

static HSTRING hstring(const wchar_t *text) {
  HSTRING s = NULL;
  if (FAILED(WindowsCreateString(text, (UINT32)wcslen(text), &s)))
    return NULL;
  return s;
}

static HRESULT factory(const wchar_t *class_name, const IID *iid, void **out) {
  HSTRING name = hstring(class_name);
  HRESULT hr = RoGetActivationFactory(name, iid, out);
  WindowsDeleteString(name);
  return hr;
}

/* An IAsyncOperation<StorageFolder> settles on a thread of the system's: this
   thread polls it, which costs a few milliseconds once per registration. */
static HRESULT folder_of_path(const wchar_t *path, void **folder) {
  void *statics = NULL, *operation = NULL, *info = NULL;
  HSTRING hpath = hstring(path);
  HRESULT hr = factory(L"Windows.Storage.StorageFolder", &iid_folder_statics,
                       &statics);
  if (SUCCEEDED(hr))
    hr = VTBL(folder_statics_vtbl, statics)
             ->GetFolderFromPathAsync(statics, hpath, &operation);
  if (SUCCEEDED(hr))
    hr = VTBL(inspectable_vtbl, operation)
             ->QueryInterface(operation, &iid_async_info, &info);
  while (SUCCEEDED(hr)) {
    AsyncStatus status;
    hr = ((IAsyncInfo *)info)->lpVtbl->get_Status((IAsyncInfo *)info, &status);
    if (FAILED(hr) || status == Completed)
      break;
    if (status != Started) {
      HRESULT code = E_FAIL;
      ((IAsyncInfo *)info)->lpVtbl->get_ErrorCode((IAsyncInfo *)info, &code);
      hr = FAILED(code) ? code : E_FAIL;
      break;
    }
    Sleep(5);
  }
  if (SUCCEEDED(hr))
    hr = VTBL(async_folder_vtbl, operation)->GetResults(operation, folder);
  release(info);
  release(operation);
  release(statics);
  WindowsDeleteString(hpath);
  return hr;
}

static void fail_hresult(const char *what, HRESULT hr) {
  char message[128];
  snprintf(message, sizeof message, "%s: HRESULT 0x%08lx", what,
           (unsigned long)hr);
  caml_failwith(message);
}

static HRESULT register_root(const wchar_t *id, const wchar_t *path,
                             const wchar_t *display_name,
                             const wchar_t *version, const wchar_t *icon) {
  void *instance = NULL, *info = NULL, *folder = NULL, *manager = NULL;
  HSTRING class_name = hstring(L"Windows.Storage.Provider.StorageProviderSyncRootInfo");
  HSTRING hid = hstring(id), hname = hstring(display_name),
          hversion = hstring(version), hicon = hstring(icon);
  HRESULT hr = RoActivateInstance(class_name, (IInspectable **)&instance);
  if (SUCCEEDED(hr))
    hr = VTBL(inspectable_vtbl, instance)
             ->QueryInterface(instance, &iid_sync_root_info, &info);
  if (SUCCEEDED(hr))
    hr = folder_of_path(path, &folder);
  if (SUCCEEDED(hr)) {
    const sync_root_info_vtbl *v = VTBL(sync_root_info_vtbl, info);
    HRESULT steps[] = {
        v->put_Id(info, hid),
        v->put_Path(info, folder),
        v->put_DisplayNameResource(info, hname),
        v->put_IconResource(info, hicon),
        v->put_Version(info, hversion),
        v->put_HydrationPolicy(info, HYDRATION_PROGRESSIVE),
        v->put_HydrationPolicyModifier(info, HYDRATION_AUTO_DEHYDRATION_ALLOWED),
        v->put_PopulationPolicy(info, POPULATION_FULL),
        v->put_InSyncPolicy(info, IN_SYNC_FILE_LAST_WRITE_TIME |
                                      IN_SYNC_PRESERVE_FOR_SYNC_ENGINE),
        v->put_HardlinkPolicy(info, HARDLINK_NONE),
        v->put_ProtectionMode(info, PROTECTION_PERSONAL),
        v->put_AllowPinning(info, TRUE),
        v->put_ShowSiblingsAsGroup(info, FALSE),
    };
    for (size_t i = 0; i < sizeof steps / sizeof steps[0] && SUCCEEDED(hr); i++)
      hr = steps[i];
  }
  if (SUCCEEDED(hr))
    hr = factory(L"Windows.Storage.Provider.StorageProviderSyncRootManager",
                 &iid_sync_root_manager, &manager);
  if (SUCCEEDED(hr))
    hr = VTBL(sync_root_manager_vtbl, manager)->Register(manager, info);
  release(manager);
  release(folder);
  release(info);
  release(instance);
  WindowsDeleteString(class_name);
  WindowsDeleteString(hid);
  WindowsDeleteString(hname);
  WindowsDeleteString(hversion);
  WindowsDeleteString(hicon);
  return hr;
}

static HRESULT unregister_root(const wchar_t *id) {
  void *manager = NULL;
  HSTRING hid = hstring(id);
  HRESULT hr = factory(L"Windows.Storage.Provider.StorageProviderSyncRootManager",
                       &iid_sync_root_manager, &manager);
  if (SUCCEEDED(hr))
    hr = VTBL(sync_root_manager_vtbl, manager)->Unregister(manager, hid);
  release(manager);
  WindowsDeleteString(hid);
  return hr;
}

/* Every call runs in the process's multithreaded apartment; a thread that
   joined it already is told so, which is not a failure. */
static HRESULT enter_apartment(void) {
  HRESULT hr = RoInitialize(RO_INIT_MULTITHREADED);
  return hr == S_FALSE ? S_OK : hr;
}

CAMLprim value tsync_cf_register(value _id, value _path, value _display_name,
                                 value _version, value _icon) {
  CAMLparam5(_id, _path, _display_name, _version, _icon);
  wchar_t *id = utf16_of_value(_id), *path = utf16_of_value(_path),
          *display_name = utf16_of_value(_display_name),
          *version = utf16_of_value(_version), *icon = utf16_of_value(_icon);
  caml_release_runtime_system();
  HRESULT hr = enter_apartment();
  if (SUCCEEDED(hr))
    hr = register_root(id, path, display_name, version, icon);
  caml_acquire_runtime_system();
  free(id);
  free(path);
  free(display_name);
  free(version);
  free(icon);
  if (FAILED(hr))
    fail_hresult("registering the sync root", hr);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_cf_unregister(value _id) {
  CAMLparam1(_id);
  wchar_t *id = utf16_of_value(_id);
  caml_release_runtime_system();
  HRESULT hr = enter_apartment();
  if (SUCCEEDED(hr))
    hr = unregister_root(id);
  caml_acquire_runtime_system();
  free(id);
  if (FAILED(hr))
    fail_hresult("unregistering the sync root", hr);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_cf_user_sid(value _unit) {
  CAMLparam1(_unit);
  CAMLlocal1(_sid);
  HANDLE token;
  char buffer[256];
  DWORD length;
  wchar_t *text = NULL;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
    caml_failwith("the process token cannot be read");
  BOOL ok = GetTokenInformation(token, TokenUser, buffer, sizeof buffer, &length) &&
            ConvertSidToStringSidW(((TOKEN_USER *)buffer)->User.Sid, &text);
  CloseHandle(token);
  if (!ok)
    caml_failwith("the user's SID cannot be read");
  _sid = value_of_utf16(text);
  LocalFree(text);
  CAMLreturn(_sid);
}

static value value_of_hstring(HSTRING s) {
  UINT32 length = 0;
  const wchar_t *text = WindowsGetStringRawBuffer(s, &length);
  return value_of_utf16_length(text, (int)length);
}

/* Every sync root registered for this user, as (id, path) (§13.1). */
CAMLprim value tsync_cf_registered(value _unit) {
  CAMLparam1(_unit);
  CAMLlocal4(_list, _cell, _pair, _text);
  void *manager = NULL, *roots = NULL;
  UINT32 count = 0;
  caml_release_runtime_system();
  HRESULT hr = enter_apartment();
  if (SUCCEEDED(hr))
    hr = factory(L"Windows.Storage.Provider.StorageProviderSyncRootManager",
                 &iid_sync_root_manager, &manager);
  if (SUCCEEDED(hr))
    hr = VTBL(sync_root_manager_vtbl, manager)->GetCurrentSyncRoots(manager, &roots);
  if (SUCCEEDED(hr))
    hr = VTBL(vector_view_vtbl, roots)->get_Size(roots, &count);
  caml_acquire_runtime_system();
  if (FAILED(hr)) {
    release(roots);
    release(manager);
    fail_hresult("listing the sync roots", hr);
  }
  _list = Val_emptylist;
  for (UINT32 i = 0; i < count; i++) {
    void *info = NULL, *folder = NULL, *item = NULL;
    HSTRING id = NULL, path = NULL;
    caml_release_runtime_system();
    HRESULT step = VTBL(vector_view_vtbl, roots)->GetAt(roots, i, &info);
    if (SUCCEEDED(step))
      step = VTBL(sync_root_info_vtbl, info)->get_Id(info, &id);
    if (SUCCEEDED(step))
      step = VTBL(sync_root_info_vtbl, info)->get_Path(info, &folder);
    if (SUCCEEDED(step))
      step = VTBL(inspectable_vtbl, folder)->QueryInterface(folder, &iid_storage_item, &item);
    if (SUCCEEDED(step))
      step = VTBL(storage_item_vtbl, item)->get_Path(item, &path);
    caml_acquire_runtime_system();
    if (SUCCEEDED(step)) {
      _pair = caml_alloc_tuple(2);
      _text = value_of_hstring(id);
      Store_field(_pair, 0, _text);
      _text = value_of_hstring(path);
      Store_field(_pair, 1, _text);
      _cell = caml_alloc_small(2, 0);
      Field(_cell, 0) = _pair;
      Field(_cell, 1) = _list;
      _list = _cell;
    }
    WindowsDeleteString(id);
    WindowsDeleteString(path);
    release(item);
    release(folder);
    release(info);
  }
  release(roots);
  release(manager);
  CAMLreturn(_list);
}
