/* Built into tsync_dbus_dl only: every libdbus call goes through a pointer
   resolved by dlopen, so a binary linking it declares no dependency on the
   library and runs without it (security-model §10.6). */
#include <dlfcn.h>

#define TSYNC_DBUS_FUNCTIONS(X) \
  X(dbus_bus_register) \
  X(dbus_connection_close) \
  X(dbus_connection_get_unix_fd) \
  X(dbus_connection_has_messages_to_send) \
  X(dbus_connection_open_private) \
  X(dbus_connection_pop_message) \
  X(dbus_connection_read_write) \
  X(dbus_connection_send) \
  X(dbus_connection_set_exit_on_disconnect) \
  X(dbus_connection_unref) \
  X(dbus_error_free) \
  X(dbus_error_init) \
  X(dbus_free) \
  X(dbus_message_get_error_name) \
  X(dbus_message_get_interface) \
  X(dbus_message_get_member) \
  X(dbus_message_get_no_reply) \
  X(dbus_message_get_path) \
  X(dbus_message_get_reply_serial) \
  X(dbus_message_get_type) \
  X(dbus_message_iter_abandon_container) \
  X(dbus_message_iter_append_basic) \
  X(dbus_message_iter_close_container) \
  X(dbus_message_iter_get_arg_type) \
  X(dbus_message_iter_get_basic) \
  X(dbus_message_iter_get_signature) \
  X(dbus_message_iter_init) \
  X(dbus_message_iter_init_append) \
  X(dbus_message_iter_next) \
  X(dbus_message_iter_open_container) \
  X(dbus_message_iter_recurse) \
  X(dbus_message_new_error) \
  X(dbus_message_new_method_call) \
  X(dbus_message_new_method_return) \
  X(dbus_message_new_signal) \
  X(dbus_message_unref) \
  X(dbus_signature_validate) \
  X(dbus_signature_validate_single) \
  X(dbus_threads_init_default) \
  X(dbus_validate_bus_name) \
  X(dbus_validate_error_name) \
  X(dbus_validate_interface) \
  X(dbus_validate_member) \
  X(dbus_validate_path) \
  X(dbus_validate_utf8)

#define TSYNC_DBUS_POINTER(name) static __typeof__(name) *tsync_dl_##name;
TSYNC_DBUS_FUNCTIONS(TSYNC_DBUS_POINTER)

#define dbus_bus_register (*tsync_dl_dbus_bus_register)
#define dbus_connection_close (*tsync_dl_dbus_connection_close)
#define dbus_connection_get_unix_fd (*tsync_dl_dbus_connection_get_unix_fd)
#define dbus_connection_has_messages_to_send (*tsync_dl_dbus_connection_has_messages_to_send)
#define dbus_connection_open_private (*tsync_dl_dbus_connection_open_private)
#define dbus_connection_pop_message (*tsync_dl_dbus_connection_pop_message)
#define dbus_connection_read_write (*tsync_dl_dbus_connection_read_write)
#define dbus_connection_send (*tsync_dl_dbus_connection_send)
#define dbus_connection_set_exit_on_disconnect (*tsync_dl_dbus_connection_set_exit_on_disconnect)
#define dbus_connection_unref (*tsync_dl_dbus_connection_unref)
#define dbus_error_free (*tsync_dl_dbus_error_free)
#define dbus_error_init (*tsync_dl_dbus_error_init)
#define dbus_free (*tsync_dl_dbus_free)
#define dbus_message_get_error_name (*tsync_dl_dbus_message_get_error_name)
#define dbus_message_get_interface (*tsync_dl_dbus_message_get_interface)
#define dbus_message_get_member (*tsync_dl_dbus_message_get_member)
#define dbus_message_get_no_reply (*tsync_dl_dbus_message_get_no_reply)
#define dbus_message_get_path (*tsync_dl_dbus_message_get_path)
#define dbus_message_get_reply_serial (*tsync_dl_dbus_message_get_reply_serial)
#define dbus_message_get_type (*tsync_dl_dbus_message_get_type)
#define dbus_message_iter_abandon_container (*tsync_dl_dbus_message_iter_abandon_container)
#define dbus_message_iter_append_basic (*tsync_dl_dbus_message_iter_append_basic)
#define dbus_message_iter_close_container (*tsync_dl_dbus_message_iter_close_container)
#define dbus_message_iter_get_arg_type (*tsync_dl_dbus_message_iter_get_arg_type)
#define dbus_message_iter_get_basic (*tsync_dl_dbus_message_iter_get_basic)
#define dbus_message_iter_get_signature (*tsync_dl_dbus_message_iter_get_signature)
#define dbus_message_iter_init (*tsync_dl_dbus_message_iter_init)
#define dbus_message_iter_init_append (*tsync_dl_dbus_message_iter_init_append)
#define dbus_message_iter_next (*tsync_dl_dbus_message_iter_next)
#define dbus_message_iter_open_container (*tsync_dl_dbus_message_iter_open_container)
#define dbus_message_iter_recurse (*tsync_dl_dbus_message_iter_recurse)
#define dbus_message_new_error (*tsync_dl_dbus_message_new_error)
#define dbus_message_new_method_call (*tsync_dl_dbus_message_new_method_call)
#define dbus_message_new_method_return (*tsync_dl_dbus_message_new_method_return)
#define dbus_message_new_signal (*tsync_dl_dbus_message_new_signal)
#define dbus_message_unref (*tsync_dl_dbus_message_unref)
#define dbus_signature_validate (*tsync_dl_dbus_signature_validate)
#define dbus_signature_validate_single (*tsync_dl_dbus_signature_validate_single)
#define dbus_threads_init_default (*tsync_dl_dbus_threads_init_default)
#define dbus_validate_bus_name (*tsync_dl_dbus_validate_bus_name)
#define dbus_validate_error_name (*tsync_dl_dbus_validate_error_name)
#define dbus_validate_interface (*tsync_dl_dbus_validate_interface)
#define dbus_validate_member (*tsync_dl_dbus_validate_member)
#define dbus_validate_path (*tsync_dl_dbus_validate_path)
#define dbus_validate_utf8 (*tsync_dl_dbus_validate_utf8)

/* Resolves every function once; false when the library or one of them is
   missing, and nothing is then called. */
static int tsync_dbus_load(void) {
  static int loaded = -1;
  if (loaded >= 0)
    return loaded;
  void *library = dlopen("libdbus-1.so.3", RTLD_NOW | RTLD_LOCAL);
  loaded = library != NULL;
#define TSYNC_DBUS_RESOLVE(name)                                               \
  if (loaded && (tsync_dl_##name = dlsym(library, #name)) == NULL)            \
    loaded = 0;
  TSYNC_DBUS_FUNCTIONS(TSYNC_DBUS_RESOLVE)
  return loaded;
}
