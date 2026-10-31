/* The part of the Cloud Filter API (cfapi.h, cldapi.dll) the provider uses,
   which mingw-w64 does not declare. Layouts and values follow Microsoft's API
   metadata as the windows-sys 0.59 crate renders it (MIT or Apache-2.0). */

#ifndef TSYNC_CF_API_H
#define TSYNC_CF_API_H

#include <windows.h>

typedef LONG CF_NTSTATUS;
typedef LONGLONG CF_CONNECTION_KEY;

enum {
  CF_CALLBACK_TYPE_FETCH_DATA = 0,
  CF_CALLBACK_TYPE_CANCEL_FETCH_DATA = 2,
  CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS = 3,
  CF_CALLBACK_TYPE_CANCEL_FETCH_PLACEHOLDERS = 4,
  CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION = 6,
  CF_CALLBACK_TYPE_NOTIFY_DEHYDRATE = 7,
  CF_CALLBACK_TYPE_NOTIFY_DELETE = 9,
  CF_CALLBACK_TYPE_NOTIFY_RENAME = 11,
  CF_CALLBACK_TYPE_NONE = -1
};

enum {
  CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO = 2,
  CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH = 4
};

enum {
  CF_OPERATION_TYPE_TRANSFER_DATA = 0,
  CF_OPERATION_TYPE_ACK_DEHYDRATE = 5,
  CF_OPERATION_TYPE_ACK_DELETE = 6,
  CF_OPERATION_TYPE_ACK_RENAME = 7,
  CF_OPERATION_TYPE_TRANSFER_PLACEHOLDERS = 4
};

enum {
  CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_DISABLE_ON_DEMAND_POPULATION = 2
};

enum {
  CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION = 1,
  CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC = 2
};

enum { CF_CALLBACK_DELETE_FLAG_IS_DIRECTORY = 1 };
enum { CF_CALLBACK_RENAME_FLAG_IS_DIRECTORY = 1, CF_CALLBACK_RENAME_FLAG_TARGET_IN_SCOPE = 4 };

typedef struct CF_PROCESS_INFO {
  DWORD StructSize;
  DWORD ProcessId;
  PCWSTR ImagePath;
  PCWSTR PackageName;
  PCWSTR ApplicationId;
  PCWSTR CommandLine;
  DWORD SessionId;
} CF_PROCESS_INFO;

typedef struct CF_CALLBACK_INFO {
  DWORD StructSize;
  CF_CONNECTION_KEY ConnectionKey;
  LPVOID CallbackContext;
  PCWSTR VolumeGuidName;
  PCWSTR VolumeDosName;
  DWORD VolumeSerialNumber;
  LONGLONG SyncRootFileId;
  LPCVOID SyncRootIdentity;
  DWORD SyncRootIdentityLength;
  LONGLONG FileId;
  LONGLONG FileSize;
  LPCVOID FileIdentity;
  DWORD FileIdentityLength;
  PCWSTR NormalizedPath;
  LONGLONG TransferKey;
  UCHAR PriorityHint;
  void *CorrelationVector;
  CF_PROCESS_INFO *ProcessInfo;
  LONGLONG RequestKey;
} CF_CALLBACK_INFO;

typedef struct CF_CALLBACK_PARAMETERS {
  DWORD ParamSize;
  union {
    struct {
      LONG Flags;
      union {
        struct {
          LONGLONG FileOffset;
          LONGLONG Length;
        } FetchData;
      };
    } Cancel;
    struct {
      LONG Flags;
      LONGLONG RequiredFileOffset;
      LONGLONG RequiredLength;
      LONGLONG OptionalFileOffset;
      LONGLONG OptionalLength;
      LONGLONG LastDehydrationTime;
      LONG LastDehydrationReason;
    } FetchData;
    struct {
      LONG Flags;
      LONGLONG RequiredFileOffset;
      LONGLONG RequiredLength;
    } ValidateData;
    struct {
      LONG Flags;
      PCWSTR Pattern;
    } FetchPlaceholders;
    struct {
      LONG Flags;
    } CloseCompletion;
    struct {
      LONG Flags;
      LONG Reason;
    } Dehydrate;
    struct {
      LONG Flags;
    } Delete;
    struct {
      LONG Flags;
      PCWSTR TargetPath;
    } Rename;
  };
} CF_CALLBACK_PARAMETERS;

typedef void(CALLBACK *CF_CALLBACK)(const CF_CALLBACK_INFO *info,
                                     const CF_CALLBACK_PARAMETERS *parameters);

typedef struct CF_CALLBACK_REGISTRATION {
  LONG Type;
  CF_CALLBACK Callback;
} CF_CALLBACK_REGISTRATION;

typedef struct CF_FS_METADATA {
  FILE_BASIC_INFO BasicInfo;
  LARGE_INTEGER FileSize;
} CF_FS_METADATA;

typedef struct CF_PLACEHOLDER_CREATE_INFO {
  PCWSTR RelativeFileName;
  CF_FS_METADATA FsMetadata;
  LPCVOID FileIdentity;
  DWORD FileIdentityLength;
  LONG Flags;
  HRESULT Result;
  LONGLONG CreateUsn;
} CF_PLACEHOLDER_CREATE_INFO;

typedef struct CF_OPERATION_INFO {
  DWORD StructSize;
  LONG Type;
  CF_CONNECTION_KEY ConnectionKey;
  LONGLONG TransferKey;
  const void *CorrelationVector;
  const void *SyncStatus;
  LONGLONG RequestKey;
} CF_OPERATION_INFO;

typedef struct CF_OPERATION_PARAMETERS {
  DWORD ParamSize;
  union {
    struct {
      LONG Flags;
      CF_NTSTATUS CompletionStatus;
      LPCVOID Buffer;
      LONGLONG Offset;
      LONGLONG Length;
    } TransferData;
    struct {
      LONG Flags;
      CF_NTSTATUS CompletionStatus;
      LONGLONG Offset;
      LONGLONG Length;
    } AckData;
    struct {
      LONG Flags;
      CF_NTSTATUS CompletionStatus;
      LONGLONG PlaceholderTotalCount;
      CF_PLACEHOLDER_CREATE_INFO *PlaceholderArray;
      DWORD PlaceholderCount;
      DWORD EntriesProcessed;
    } TransferPlaceholders;
    struct {
      LONG Flags;
      CF_NTSTATUS CompletionStatus;
      LPCVOID FileIdentity;
      DWORD FileIdentityLength;
    } AckDehydrate;
    struct {
      LONG Flags;
      CF_NTSTATUS CompletionStatus;
    } AckRename;
    struct {
      LONG Flags;
      CF_NTSTATUS CompletionStatus;
    } AckDelete;
  };
} CF_OPERATION_PARAMETERS;

#define CF_SIZE_OF_OP_PARAM(field)                                             \
  (FIELD_OFFSET(CF_OPERATION_PARAMETERS, field) +                              \
   sizeof(((CF_OPERATION_PARAMETERS *)0)->field))

typedef struct CF_PLACEHOLDER_BASIC_INFO {
  LONG PinState;
  LONG InSyncState;
  LONGLONG FileId;
  LONGLONG SyncRootFileId;
  DWORD FileIdentityLength;
  BYTE FileIdentity[1];
} CF_PLACEHOLDER_BASIC_INFO;

enum { CF_PLACEHOLDER_INFO_BASIC = 0 };

/* The functions, loaded from cldapi.dll at start. */
typedef HRESULT(WINAPI *CfConnectSyncRoot_t)(PCWSTR, const CF_CALLBACK_REGISTRATION *,
                                             LPCVOID, LONG, CF_CONNECTION_KEY *);
typedef HRESULT(WINAPI *CfDisconnectSyncRoot_t)(CF_CONNECTION_KEY);
typedef HRESULT(WINAPI *CfExecute_t)(const CF_OPERATION_INFO *, CF_OPERATION_PARAMETERS *);
enum {
  CF_CONVERT_FLAG_MARK_IN_SYNC = 1,
  CF_UPDATE_FLAG_MARK_IN_SYNC = 2
};

typedef HRESULT(WINAPI *CfConvertToPlaceholder_t)(HANDLE, LPCVOID, DWORD, LONG, LONGLONG *,
                                                  LPOVERLAPPED);
typedef HRESULT(WINAPI *CfUpdatePlaceholder_t)(HANDLE, const CF_FS_METADATA *, LPCVOID, DWORD,
                                               const void *, DWORD, LONG, LONGLONG *,
                                               LPOVERLAPPED);
enum { CF_UPDATE_FLAG_DEHYDRATE = 4 };

typedef HRESULT(WINAPI *CfDehydratePlaceholder_t)(HANDLE, LONGLONG, LONGLONG, LONG,
                                                  LPOVERLAPPED);
typedef HRESULT(WINAPI *CfRevertPlaceholder_t)(HANDLE, LONG, LPOVERLAPPED);
typedef HRESULT(WINAPI *CfCreatePlaceholders_t)(PCWSTR, CF_PLACEHOLDER_CREATE_INFO *, DWORD,
                                                LONG, PDWORD);
typedef HRESULT(WINAPI *CfGetPlaceholderInfo_t)(HANDLE, LONG, PVOID, DWORD, PDWORD);
typedef HRESULT(WINAPI *CfHydratePlaceholder_t)(HANDLE, LONGLONG, LONGLONG, LONG,
                                                LPOVERLAPPED);

#endif
