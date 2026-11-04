/* The Windows tray (cloud-files §15): a notification-area icon and its popup
   menu, on a UI thread of its own that reads only the snapshot OCaml last
   pushed and hands every click back through a queue, so it never waits on an
   owner. */

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <shellapi.h>

#define WM_TRAY (WM_APP + 1)
#define WM_POPUP (WM_APP + 2)
#define TRAY_ID 1
#define FIRST_COMMAND 1000
#define ICON_BASE 101

/* A menu row as the snapshot holds it: a submenu row's [index] is its key, any
   other row's the id its click reports. */
typedef struct row {
  wchar_t *label;
  int index;
  BOOL separator, enabled, submenu;
  int checked; /* -1 no checkmark, 0 unchecked, 1 checked */
  struct row *children;
  int child_count;
} row;

static CRITICAL_SECTION lock;
static row *rows;
static int row_count;
static HMENU submenus[8];
static int submenu_keys[8], submenu_count;
static HWND window;
static UINT taskbar_created;
static int icon_state; /* 0 idle, 1 sync, 2 paused, 3 error */
static wchar_t tooltip[128] = L"tsync";

typedef struct event {
  int kind; /* 0 opened, 1 clicked, 2 ended */
  int index;
} event;

static event queue[64];
static int queue_head, queue_count;
static HANDLE queued;

static void push(int kind, int index) {
  EnterCriticalSection(&lock);
  if (queue_count < 64) {
    queue[(queue_head + queue_count) % 64] = (event){kind, index};
    queue_count++;
  }
  LeaveCriticalSection(&lock);
  ReleaseSemaphore(queued, 1, NULL);
}

static wchar_t *wide(value _text) {
  int units = MultiByteToWideChar(CP_UTF8, 0, String_val(_text),
                                  (int)caml_string_length(_text), NULL, 0);
  wchar_t *w = malloc(((size_t)units + 1) * sizeof(wchar_t));
  if (w == NULL)
    caml_raise_out_of_memory();
  MultiByteToWideChar(CP_UTF8, 0, String_val(_text), (int)caml_string_length(_text),
                      w, units);
  w[units] = 0;
  return w;
}

static value narrow(const wchar_t *w) {
  int bytes = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  value _text = caml_alloc_string(bytes > 0 ? bytes - 1 : 0);
  if (bytes > 1)
    WideCharToMultiByte(CP_UTF8, 0, w, -1, (char *)Bytes_val(_text), bytes - 1, NULL,
                        NULL);
  return _text;
}

static void free_rows(row *r, int n) {
  for (int i = 0; i < n; i++) {
    free(r[i].label);
    free_rows(r[i].children, r[i].child_count);
  }
  free(r);
}

/* [_rows]: an array of (label, index, separator, enabled, checked, children). */
static row *rows_of_value(value _rows, int *count) {
  mlsize_t n = Wosize_val(_rows);
  row *r = calloc(n == 0 ? 1 : n, sizeof *r);
  if (r == NULL)
    caml_raise_out_of_memory();
  for (mlsize_t i = 0; i < n; i++) {
    value _r = Field(_rows, i);
    r[i].label = wide(Field(_r, 0));
    r[i].index = Int_val(Field(_r, 1));
    r[i].separator = Bool_val(Field(_r, 2));
    r[i].enabled = Bool_val(Field(_r, 3));
    r[i].checked = Int_val(Field(_r, 4));
    r[i].submenu = Wosize_val(Field(_r, 5)) > 0;
    r[i].children = rows_of_value(Field(_r, 5), &r[i].child_count);
  }
  *count = (int)n;
  return r;
}

CAMLprim value tsync_wtray_set_menu(value _rows) {
  CAMLparam1(_rows);
  int count;
  row *fresh = rows_of_value(_rows, &count);
  EnterCriticalSection(&lock);
  free_rows(rows, row_count);
  rows = fresh;
  row_count = count;
  LeaveCriticalSection(&lock);
  CAMLreturn(Val_unit);
}

static void fill(HMENU menu, row *r, int n, BOOL top) {
  for (int i = 0; i < n; i++) {
    if (r[i].separator) {
      AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
      continue;
    }
    UINT flags = MF_STRING | (r[i].enabled ? 0 : MF_GRAYED) |
                 (r[i].checked == 1 ? MF_CHECKED : 0);
    if (r[i].submenu) {
      HMENU sub = CreatePopupMenu();
      fill(sub, r[i].children, r[i].child_count, FALSE);
      AppendMenuW(menu, flags | MF_POPUP, (UINT_PTR)sub, r[i].label);
      if (top && submenu_count < 8) {
        submenus[submenu_count] = sub;
        submenu_keys[submenu_count++] = r[i].index;
      }
    } else
      AppendMenuW(menu, flags, FIRST_COMMAND + r[i].index, r[i].label);
  }
}

/* A top-level submenu shows the rows of the latest snapshot as it opens, since
   its rows are fetched once the menu is already up. */
static void refill(HMENU menu) {
  for (int s = 0; s < submenu_count; s++) {
    if (submenus[s] != menu)
      continue;
    while (GetMenuItemCount(menu) > 0)
      DeleteMenu(menu, 0, MF_BYPOSITION);
    EnterCriticalSection(&lock);
    for (int i = 0; i < row_count; i++)
      if (rows[i].submenu && rows[i].index == submenu_keys[s])
        fill(menu, rows[i].children, rows[i].child_count, FALSE);
    LeaveCriticalSection(&lock);
  }
}

/* The taskbar's theme picks the glyph's colour: a light taskbar takes the dark
   one. */
static BOOL light_taskbar(void) {
  DWORD light = 0, size = sizeof light;
  RegGetValueW(HKEY_CURRENT_USER,
               L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
               L"SystemUsesLightTheme", RRF_RT_REG_DWORD, NULL, &light, &size);
  return light != 0;
}

static void notify_icon(DWORD message) {
  NOTIFYICONDATAW data = {0};
  data.cbSize = sizeof data;
  data.hWnd = window;
  data.uID = TRAY_ID;
  data.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
  data.uCallbackMessage = WM_TRAY;
  data.hIcon = LoadIconW(GetModuleHandleW(NULL),
                         MAKEINTRESOURCEW(ICON_BASE + icon_state * 2 + (light_taskbar() ? 1 : 0)));
  EnterCriticalSection(&lock);
  wcsncpy(data.szTip, tooltip, sizeof data.szTip / sizeof data.szTip[0] - 1);
  LeaveCriticalSection(&lock);
  Shell_NotifyIconW(message, &data);
}

static void popup(void) {
  POINT at;
  GetCursorPos(&at);
  HMENU menu = CreatePopupMenu();
  submenu_count = 0;
  EnterCriticalSection(&lock);
  fill(menu, rows, row_count, TRUE);
  LeaveCriticalSection(&lock);
  push(0, 0);
  /* A popup menu closes on a click elsewhere only while its window is in the
     foreground. */
  SetForegroundWindow(window);
  int command =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, at.x, at.y, 0, window, NULL);
  PostMessageW(window, WM_NULL, 0, 0);
  DestroyMenu(menu);
  submenu_count = 0;
  if (command >= FIRST_COMMAND)
    push(1, command - FIRST_COMMAND);
}

static LRESULT CALLBACK window_proc(HWND w, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == taskbar_created) {
    notify_icon(NIM_ADD);
    return 0;
  }
  switch (message) {
  case WM_TRAY:
    if (LOWORD(lparam) == WM_LBUTTONUP || LOWORD(lparam) == WM_RBUTTONUP)
      PostMessageW(w, WM_POPUP, 0, 0);
    return 0;
  case WM_POPUP:
    popup();
    return 0;
  case WM_INITMENUPOPUP:
    refill((HMENU)wparam);
    return 0;
  case WM_SETTINGCHANGE:
    notify_icon(NIM_MODIFY);
    return 0;
  case WM_ENDSESSION:
    if (wparam)
      push(2, 0);
    return 0;
  }
  return DefWindowProcW(w, message, wparam, lparam);
}

static DWORD WINAPI ui_thread(LPVOID ready) {
  WNDCLASSW class = {0};
  class.lpfnWndProc = window_proc;
  class.hInstance = GetModuleHandleW(NULL);
  class.lpszClassName = L"tsync-tray";
  RegisterClassW(&class);
  window = CreateWindowExW(0, L"tsync-tray", L"tsync", 0, 0, 0, 0, 0, NULL, NULL,
                           class.hInstance, NULL);
  taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  notify_icon(NIM_ADD);
  SetEvent((HANDLE)ready);
  MSG message;
  while (GetMessageW(&message, NULL, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  push(2, 0);
  return 0;
}

/* §15: one tray per session; [false] when another holds the mutex. */
CAMLprim value tsync_wtray_single(value _unit) {
  CAMLparam1(_unit);
  HANDLE mutex = CreateMutexW(NULL, TRUE, L"Local\\org.feverdreamtv.tsync.tray");
  CAMLreturn(Val_bool(mutex != NULL && GetLastError() != ERROR_ALREADY_EXISTS));
}

CAMLprim value tsync_wtray_start(value _unit) {
  CAMLparam1(_unit);
  InitializeCriticalSection(&lock);
  queued = CreateSemaphoreW(NULL, 0, 64, NULL);
  HANDLE ready = CreateEventW(NULL, TRUE, FALSE, NULL);
  HANDLE thread = CreateThread(NULL, 0, ui_thread, ready, 0, NULL);
  if (thread == NULL)
    caml_failwith("the tray's interface thread cannot start");
  CloseHandle(thread);
  caml_release_runtime_system();
  WaitForSingleObject(ready, INFINITE);
  caml_acquire_runtime_system();
  CloseHandle(ready);
  CAMLreturn(Val_unit);
}

/* (kind, row): 0 opened, 1 clicked, 2 ended. */
CAMLprim value tsync_wtray_next(value _unit) {
  CAMLparam1(_unit);
  CAMLlocal1(_event);
  caml_release_runtime_system();
  WaitForSingleObject(queued, INFINITE);
  caml_acquire_runtime_system();
  EnterCriticalSection(&lock);
  event e = queue[queue_head];
  queue_head = (queue_head + 1) % 64;
  queue_count--;
  LeaveCriticalSection(&lock);
  _event = caml_alloc_tuple(2);
  Store_field(_event, 0, Val_int(e.kind));
  Store_field(_event, 1, Val_int(e.index));
  CAMLreturn(_event);
}

CAMLprim value tsync_wtray_set_icon(value _state, value _tooltip) {
  CAMLparam2(_state, _tooltip);
  wchar_t *tip = wide(_tooltip);
  EnterCriticalSection(&lock);
  icon_state = Int_val(_state);
  wcsncpy(tooltip, tip, sizeof tooltip / sizeof tooltip[0] - 1);
  tooltip[sizeof tooltip / sizeof tooltip[0] - 1] = 0;
  LeaveCriticalSection(&lock);
  free(tip);
  notify_icon(NIM_MODIFY);
  CAMLreturn(Val_unit);
}

/* §15: a notification is the icon's balloon. */
CAMLprim value tsync_wtray_notify(value _title, value _body) {
  CAMLparam2(_title, _body);
  wchar_t *title = wide(_title), *body = wide(_body);
  NOTIFYICONDATAW data = {0};
  data.cbSize = sizeof data;
  data.hWnd = window;
  data.uID = TRAY_ID;
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO;
  wcsncpy(data.szInfoTitle, title, sizeof data.szInfoTitle / sizeof data.szInfoTitle[0] - 1);
  wcsncpy(data.szInfo, body, sizeof data.szInfo / sizeof data.szInfo[0] - 1);
  Shell_NotifyIconW(NIM_MODIFY, &data);
  free(title);
  free(body);
  CAMLreturn(Val_unit);
}

static BOOL set_dword_format(const wchar_t *name, DWORD value_) {
  HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
  if (h == NULL)
    return FALSE;
  *(DWORD *)GlobalLock(h) = value_;
  GlobalUnlock(h);
  if (SetClipboardData(RegisterClipboardFormatW(name), h) == NULL) {
    GlobalFree(h);
    return FALSE;
  }
  return TRUE;
}

/* §15: the code as text, with the formats that keep it out of clipboard
   monitors, clipboard history and cloud clipboard; never logged nor kept. */
CAMLprim value tsync_wtray_copy(value _text) {
  CAMLparam1(_text);
  wchar_t *text = wide(_text);
  size_t bytes = (wcslen(text) + 1) * sizeof(wchar_t);
  BOOL ok = FALSE;
  if (OpenClipboard(window)) {
    EmptyClipboard();
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (h != NULL) {
      memcpy(GlobalLock(h), text, bytes);
      GlobalUnlock(h);
      ok = SetClipboardData(CF_UNICODETEXT, h) != NULL;
      if (!ok)
        GlobalFree(h);
    }
    ok = ok && set_dword_format(L"ExcludeClipboardContentFromMonitorProcessing", 0) &&
         set_dword_format(L"CanIncludeInClipboardHistory", 0) &&
         set_dword_format(L"CanUploadToCloudClipboard", 0);
    CloseClipboard();
  }
  SecureZeroMemory(text, bytes);
  free(text);
  CAMLreturn(Val_bool(ok));
}

/* §15: Open folder opens it; Reveal opens its folder with the item selected
   and never opens the file. */
CAMLprim value tsync_wtray_show(value _path, value _folder) {
  CAMLparam2(_path, _folder);
  wchar_t *path = wide(_path);
  if (Bool_val(_folder))
    ShellExecuteW(NULL, L"open", path, NULL, NULL, SW_SHOWNORMAL);
  else {
    size_t n = wcslen(path) + 16;
    wchar_t *arguments = malloc(n * sizeof(wchar_t));
    if (arguments != NULL) {
      swprintf(arguments, n, L"/select,\"%ls\"", path);
      ShellExecuteW(NULL, L"open", L"explorer.exe", arguments, NULL, SW_SHOWNORMAL);
      free(arguments);
    }
  }
  free(path);
  CAMLreturn(Val_unit);
}

/* The unlock dialog (§15): a prompt, a hidden entry, a Show box, OK and Cancel,
   laid out from an in-memory template. */
#define ID_TEXT 100
#define ID_ENTRY 101
#define ID_SHOW 102

typedef struct dialog_state {
  const wchar_t *prompt;
  wchar_t answer[512];
} dialog_state;

static INT_PTR CALLBACK dialog_proc(HWND dialog, UINT message, WPARAM wparam, LPARAM lparam) {
  dialog_state *state = (dialog_state *)GetWindowLongPtrW(dialog, DWLP_USER);
  switch (message) {
  case WM_INITDIALOG:
    SetWindowLongPtrW(dialog, DWLP_USER, lparam);
    SetDlgItemTextW(dialog, ID_TEXT, ((dialog_state *)lparam)->prompt);
    SetForegroundWindow(dialog);
    SetFocus(GetDlgItem(dialog, ID_ENTRY));
    return FALSE;
  case WM_COMMAND:
    switch (LOWORD(wparam)) {
    case ID_SHOW: {
      BOOL shown = IsDlgButtonChecked(dialog, ID_SHOW) == BST_CHECKED;
      HWND entry = GetDlgItem(dialog, ID_ENTRY);
      SendMessageW(entry, EM_SETPASSWORDCHAR, shown ? 0 : (WPARAM)L'\x25CF', 0);
      InvalidateRect(entry, NULL, TRUE);
      return TRUE;
    }
    case IDOK:
      GetDlgItemTextW(dialog, ID_ENTRY, state->answer,
                      sizeof state->answer / sizeof state->answer[0]);
      EndDialog(dialog, IDOK);
      return TRUE;
    case IDCANCEL:
      EndDialog(dialog, IDCANCEL);
      return TRUE;
    }
  }
  return FALSE;
}

static WORD *align(WORD *p) { return (WORD *)(((ULONG_PTR)p + 3) & ~(ULONG_PTR)3); }

static WORD *put_string(WORD *p, const wchar_t *s) {
  while ((*p++ = *s++))
    ;
  return p;
}

static WORD *put_item(WORD *p, DWORD style, short x, short y, short cx, short cy,
                      WORD id, WORD class_atom, const wchar_t *text) {
  p = align(p);
  DLGITEMTEMPLATE *item = (DLGITEMTEMPLATE *)p;
  item->style = style | WS_CHILD | WS_VISIBLE;
  item->x = x;
  item->y = y;
  item->cx = cx;
  item->cy = cy;
  item->id = id;
  p = (WORD *)(item + 1);
  *p++ = 0xFFFF;
  *p++ = class_atom;
  p = put_string(p, text);
  *p++ = 0;
  return p;
}

CAMLprim value tsync_wtray_ask(value _title, value _prompt) {
  CAMLparam2(_title, _prompt);
  CAMLlocal1(_answer);
  wchar_t *title = wide(_title), *prompt = wide(_prompt);
  WORD *buffer = calloc(4096, sizeof(WORD));
  if (buffer == NULL)
    caml_raise_out_of_memory();
  DLGTEMPLATE *t = (DLGTEMPLATE *)buffer;
  t->style = DS_MODALFRAME | DS_CENTER | DS_SETFONT | WS_POPUP | WS_CAPTION | WS_SYSMENU;
  t->dwExtendedStyle = WS_EX_TOPMOST;
  t->cdit = 5;
  t->cx = 240;
  t->cy = 96;
  WORD *p = (WORD *)(t + 1);
  *p++ = 0;
  *p++ = 0;
  p = put_string(p, title);
  *p++ = 9;
  p = put_string(p, L"Segoe UI");
  p = put_item(p, SS_LEFT, 8, 8, 224, 28, ID_TEXT, 0x0082, L"");
  p = put_item(p, ES_PASSWORD | ES_AUTOHSCROLL | WS_BORDER | WS_TABSTOP, 8, 40, 224, 14,
               ID_ENTRY, 0x0081, L"");
  p = put_item(p, BS_AUTOCHECKBOX | WS_TABSTOP, 8, 58, 80, 12, ID_SHOW, 0x0080, L"Show");
  p = put_item(p, BS_DEFPUSHBUTTON | WS_TABSTOP, 128, 76, 50, 14, IDOK, 0x0080, L"OK");
  p = put_item(p, BS_PUSHBUTTON | WS_TABSTOP, 182, 76, 50, 14, IDCANCEL, 0x0080, L"Cancel");
  dialog_state state = {prompt, {0}};
  caml_release_runtime_system();
  INT_PTR result =
      DialogBoxIndirectParamW(GetModuleHandleW(NULL), t, NULL, dialog_proc, (LPARAM)&state);
  caml_acquire_runtime_system();
  free(buffer);
  free(title);
  free(prompt);
  if (result != IDOK) {
    SecureZeroMemory(state.answer, sizeof state.answer);
    CAMLreturn(Val_none);
  }
  _answer = narrow(state.answer);
  SecureZeroMemory(state.answer, sizeof state.answer);
  CAMLreturn(caml_alloc_some(_answer));
}
