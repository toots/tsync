/* libdbus, reduced to what a tray icon needs.
 *
 * Two design points are worth stating, because both are load-bearing and
 * neither is obvious from the code:
 *
 * Iterators are malloc'd, never embedded in the custom block. OCaml 5 moves
 * custom blocks -- minor collection promotes, major collection compacts -- and
 * libdbus keeps writing through the address it was handed:
 * dbus_message_iter_close_container reads both the parent and the child struct
 * at close time, which can be many allocations after they were opened. One
 * malloc per container buys the whole question away.
 *
 * Nothing here calls dbus_connection_dispatch. Dispatch answers any method call
 * that no registered handler claimed with an automatic UnknownMethod, so using
 * it would mean either registering C vtables that call back into OCaml, or
 * racing our own replies against libdbus's. read_write + pop_message hands the
 * queue over untouched and makes the router OCaml's -- along with the duty to
 * reply to every call, which dbus.mli says out loud. */

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <dbus/dbus.h>
#include <stdlib.h>
#include <string.h>

/* Raised as Dbus.Error (name, message). Registered from dbus.ml, since an
 * exception the C side allocates itself would not be the same one OCaml
 * pattern-matches on. */
static void tsync_dbus_raise(const char *name, const char *msg) {
  static const value *exn = NULL;
  if (exn == NULL)
    exn = caml_named_value("tsync.dbus.error");
  if (exn == NULL)
    caml_failwith(msg);
  value args[2];
  args[0] = caml_copy_string(name);
  args[1] = caml_copy_string(msg);
  caml_raise_with_args(*exn, 2, args);
}

/* A DBusError filled by a libdbus call, turned into the OCaml exception and
 * freed. Returns normally when the error is unset. */
static void tsync_dbus_check(DBusError *err) {
  if (!dbus_error_is_set(err))
    return;
  char name[256], msg[1024];
  snprintf(name, sizeof(name), "%s", err->name ? err->name : "");
  snprintf(msg, sizeof(msg), "%s", err->message ? err->message : "");
  dbus_error_free(err);
  tsync_dbus_raise(name, msg);
}

/* ------------------------------------------------------------------ *
 * Connection                                                          *
 * ------------------------------------------------------------------ */

#define Connection_val(v) (*((DBusConnection **)Data_custom_val(v)))

static void tsync_connection_finalize(value v) {
  DBusConnection *conn = Connection_val(v);
  if (conn) {
    /* Private connections are ours to close; a shared one must only be
     * unref'd, which is half the reason we ask for a private one. */
    dbus_connection_close(conn);
    dbus_connection_unref(conn);
    Connection_val(v) = NULL;
  }
}

static struct custom_operations tsync_connection_ops = {
    "tsync.dbus.connection", tsync_connection_finalize,
    custom_compare_default,  custom_hash_default,
    custom_serialize_default, custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

static value tsync_alloc_connection(DBusConnection *conn) {
  value v = caml_alloc_custom(&tsync_connection_ops, sizeof(DBusConnection *), 0, 1);
  Connection_val(v) = conn;
  return v;
}

CAMLprim value tsync_dbus_bus_get(value unit) {
  CAMLparam1(unit);
  DBusError err;
  dbus_error_init(&err);
  DBusConnection *conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
  tsync_dbus_check(&err);
  if (conn == NULL)
    tsync_dbus_raise("org.freedesktop.DBus.Error.NoServer", "no session bus");
  dbus_connection_set_exit_on_disconnect(conn, FALSE);
  CAMLreturn(tsync_alloc_connection(conn));
}

CAMLprim value tsync_dbus_close(value _conn) {
  CAMLparam1(_conn);
  tsync_connection_finalize(_conn);
  CAMLreturn(Val_unit);
}

/* DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER, or 0 when the name was taken. */
CAMLprim value tsync_dbus_request_name(value _conn, value _name, value _flags) {
  CAMLparam3(_conn, _name, _flags);
  DBusError err;
  dbus_error_init(&err);
  int rc = dbus_bus_request_name(Connection_val(_conn), String_val(_name),
                                 Int_val(_flags), &err);
  tsync_dbus_check(&err);
  CAMLreturn(Val_int(rc));
}

CAMLprim value tsync_dbus_add_match(value _conn, value _rule) {
  CAMLparam2(_conn, _rule);
  DBusError err;
  dbus_error_init(&err);
  dbus_bus_add_match(Connection_val(_conn), String_val(_rule), &err);
  tsync_dbus_check(&err);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_dbus_flush(value _conn) {
  CAMLparam1(_conn);
  dbus_connection_flush(Connection_val(_conn));
  CAMLreturn(Val_unit);
}

/* ------------------------------------------------------------------ *
 * Messages                                                            *
 * ------------------------------------------------------------------ */

#define Message_val(v) (*((DBusMessage **)Data_custom_val(v)))

static void tsync_message_finalize(value v) {
  DBusMessage *msg = Message_val(v);
  if (msg) {
    dbus_message_unref(msg);
    Message_val(v) = NULL;
  }
}

static struct custom_operations tsync_message_ops = {
    "tsync.dbus.message",     tsync_message_finalize,
    custom_compare_default,   custom_hash_default,
    custom_serialize_default, custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

/* Takes ownership of [msg]: the caller's reference becomes the block's. */
static value tsync_alloc_message(DBusMessage *msg) {
  value v = caml_alloc_custom(&tsync_message_ops, sizeof(DBusMessage *), 0, 1);
  Message_val(v) = msg;
  return v;
}

CAMLprim value tsync_dbus_new_method_call(value _dest, value _path, value _iface,
                                          value _member) {
  CAMLparam4(_dest, _path, _iface, _member);
  DBusMessage *msg = dbus_message_new_method_call(
      String_val(_dest), String_val(_path),
      caml_string_length(_iface) ? String_val(_iface) : NULL,
      String_val(_member));
  /* NULL here means a malformed path or interface, not memory pressure -- a
   * programming error in the caller, so fail rather than raise a D-Bus error
   * that suggests the peer said something. */
  if (msg == NULL)
    caml_failwith("dbus: malformed method call");
  CAMLreturn(tsync_alloc_message(msg));
}

CAMLprim value tsync_dbus_new_signal(value _path, value _iface, value _member) {
  CAMLparam3(_path, _iface, _member);
  DBusMessage *msg =
      dbus_message_new_signal(String_val(_path), String_val(_iface), String_val(_member));
  if (msg == NULL)
    caml_failwith("dbus: malformed signal");
  CAMLreturn(tsync_alloc_message(msg));
}

CAMLprim value tsync_dbus_new_method_return(value _to) {
  CAMLparam1(_to);
  DBusMessage *msg = dbus_message_new_method_return(Message_val(_to));
  if (msg == NULL)
    caml_failwith("dbus: cannot answer that message");
  CAMLreturn(tsync_alloc_message(msg));
}

CAMLprim value tsync_dbus_new_error(value _to, value _name, value _text) {
  CAMLparam3(_to, _name, _text);
  DBusMessage *msg =
      dbus_message_new_error(Message_val(_to), String_val(_name), String_val(_text));
  if (msg == NULL)
    caml_failwith("dbus: cannot answer that message");
  CAMLreturn(tsync_alloc_message(msg));
}

CAMLprim value tsync_dbus_message_type(value _msg) {
  CAMLparam1(_msg);
  CAMLreturn(Val_int(dbus_message_get_type(Message_val(_msg))));
}

/* The header fields, "" where libdbus answers NULL. A router matching on them
 * has no use for the difference between absent and empty. */
#define HEADER_ACCESSOR(name, call)                                            \
  CAMLprim value name(value _msg) {                                            \
    CAMLparam1(_msg);                                                          \
    const char *s = call(Message_val(_msg));                                   \
    CAMLreturn(caml_copy_string(s ? s : ""));                                  \
  }

HEADER_ACCESSOR(tsync_dbus_message_path, dbus_message_get_path)
HEADER_ACCESSOR(tsync_dbus_message_interface, dbus_message_get_interface)
HEADER_ACCESSOR(tsync_dbus_message_member, dbus_message_get_member)
HEADER_ACCESSOR(tsync_dbus_message_sender, dbus_message_get_sender)
HEADER_ACCESSOR(tsync_dbus_message_error_name, dbus_message_get_error_name)

CAMLprim value tsync_dbus_message_no_reply(value _msg) {
  CAMLparam1(_msg);
  CAMLreturn(Val_bool(dbus_message_get_no_reply(Message_val(_msg))));
}

CAMLprim value tsync_dbus_send(value _conn, value _msg) {
  CAMLparam2(_conn, _msg);
  dbus_uint32_t serial = 0;
  if (!dbus_connection_send(Connection_val(_conn), Message_val(_msg), &serial))
    caml_failwith("dbus: out of memory sending a message");
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_dbus_send_with_reply_and_block(value _conn, value _msg,
                                                    value _timeout) {
  CAMLparam3(_conn, _msg, _timeout);
  DBusConnection *conn = Connection_val(_conn);
  DBusMessage *msg = Message_val(_msg);
  int timeout = Int_val(_timeout);
  DBusError err;
  dbus_error_init(&err);

  /* Nothing OCaml-owned is read while the lock is down: both pointers live in
   * refcounted libdbus objects the custom blocks only point at. */
  caml_release_runtime_system();
  DBusMessage *reply =
      dbus_connection_send_with_reply_and_block(conn, msg, timeout, &err);
  caml_acquire_runtime_system();

  tsync_dbus_check(&err);
  if (reply == NULL)
    tsync_dbus_raise("org.freedesktop.DBus.Error.NoReply", "no reply");
  CAMLreturn(tsync_alloc_message(reply));
}

CAMLprim value tsync_dbus_read_write(value _conn, value _timeout) {
  CAMLparam2(_conn, _timeout);
  DBusConnection *conn = Connection_val(_conn);
  int timeout = Int_val(_timeout);

  caml_release_runtime_system();
  dbus_bool_t alive = dbus_connection_read_write(conn, timeout);
  caml_acquire_runtime_system();

  CAMLreturn(Val_bool(alive));
}

CAMLprim value tsync_dbus_pop_message(value _conn) {
  CAMLparam1(_conn);
  CAMLlocal1(some);
  DBusMessage *msg = dbus_connection_pop_message(Connection_val(_conn));
  if (msg == NULL)
    CAMLreturn(Val_int(0)); /* None */
  some = caml_alloc(1, 0);  /* Some _ */
  Store_field(some, 0, tsync_alloc_message(msg));
  CAMLreturn(some);
}

/* ------------------------------------------------------------------ *
 * Iterators                                                           *
 * ------------------------------------------------------------------ */

struct tsync_iter {
  DBusMessageIter *it; /* malloc'd; see the file header */
  DBusMessage *owner;  /* referenced, so the iterator cannot outlive its bytes */
};

#define Iter_handle(v) ((struct tsync_iter *)Data_custom_val(v))
#define Iter_val(v) (Iter_handle(v)->it)

static void tsync_iter_finalize(value v) {
  struct tsync_iter *h = Iter_handle(v);
  if (h->owner) {
    dbus_message_unref(h->owner);
    h->owner = NULL;
  }
  free(h->it);
  h->it = NULL;
}

static struct custom_operations tsync_iter_ops = {
    "tsync.dbus.iter",        tsync_iter_finalize,
    custom_compare_default,   custom_hash_default,
    custom_serialize_default, custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

static value tsync_alloc_iter(DBusMessage *owner) {
  value v = caml_alloc_custom(&tsync_iter_ops, sizeof(struct tsync_iter), 0, 1);
  struct tsync_iter *h = Iter_handle(v);
  h->it = calloc(1, sizeof(DBusMessageIter));
  h->owner = NULL;
  if (h->it == NULL)
    caml_failwith("dbus: out of memory allocating an iterator");
  h->owner = owner;
  dbus_message_ref(owner);
  return v;
}

CAMLprim value tsync_dbus_iter_init_append(value _msg) {
  CAMLparam1(_msg);
  CAMLlocal1(iter);
  iter = tsync_alloc_iter(Message_val(_msg));
  dbus_message_iter_init_append(Message_val(_msg), Iter_val(iter));
  CAMLreturn(iter);
}

CAMLprim value tsync_dbus_iter_init(value _msg) {
  CAMLparam1(_msg);
  CAMLlocal1(iter);
  iter = tsync_alloc_iter(Message_val(_msg));
  dbus_message_iter_init(Message_val(_msg), Iter_val(iter));
  CAMLreturn(iter);
}

CAMLprim value tsync_dbus_iter_open(value _parent, value _type, value _sig) {
  CAMLparam3(_parent, _type, _sig);
  CAMLlocal1(sub);

  /* Copied out first: allocating [sub] can move the OCaml string, and the
   * pointer libdbus is handed has to survive that. */
  char sign[256];
  size_t len = caml_string_length(_sig);
  if (len >= sizeof(sign))
    caml_failwith("dbus: signature too long");
  memcpy(sign, String_val(_sig), len);
  sign[len] = '\0';

  int type = Int_val(_type);
  sub = tsync_alloc_iter(Iter_handle(_parent)->owner);
  if (!dbus_message_iter_open_container(Iter_val(_parent), type,
                                        sign[0] ? sign : NULL, Iter_val(sub)))
    caml_failwith("dbus: out of memory opening a container");
  CAMLreturn(sub);
}

CAMLprim value tsync_dbus_iter_close(value _parent, value _sub) {
  CAMLparam2(_parent, _sub);
  if (!dbus_message_iter_close_container(Iter_val(_parent), Iter_val(_sub)))
    caml_failwith("dbus: out of memory closing a container");
  CAMLreturn(Val_unit);
}

/* One entry point for every fixed-size type that fits in an int64, so the
 * variant-to-wire mapping stays in dbus.ml where it can be read next to the
 * type it implements. */
CAMLprim value tsync_dbus_iter_append_int(value _iter, value _type, value _v) {
  CAMLparam3(_iter, _type, _v);
  int type = Int_val(_type);
  int64_t n = Int64_val(_v);
  dbus_bool_t ok;
  switch (type) {
    case DBUS_TYPE_BYTE: {
      unsigned char v = (unsigned char)n;
      ok = dbus_message_iter_append_basic(Iter_val(_iter), type, &v);
      break;
    }
    case DBUS_TYPE_BOOLEAN: {
      dbus_bool_t v = n ? TRUE : FALSE;
      ok = dbus_message_iter_append_basic(Iter_val(_iter), type, &v);
      break;
    }
    case DBUS_TYPE_INT16: {
      dbus_int16_t v = (dbus_int16_t)n;
      ok = dbus_message_iter_append_basic(Iter_val(_iter), type, &v);
      break;
    }
    case DBUS_TYPE_UINT16: {
      dbus_uint16_t v = (dbus_uint16_t)n;
      ok = dbus_message_iter_append_basic(Iter_val(_iter), type, &v);
      break;
    }
    case DBUS_TYPE_INT32: {
      dbus_int32_t v = (dbus_int32_t)n;
      ok = dbus_message_iter_append_basic(Iter_val(_iter), type, &v);
      break;
    }
    case DBUS_TYPE_UINT32: {
      dbus_uint32_t v = (dbus_uint32_t)n;
      ok = dbus_message_iter_append_basic(Iter_val(_iter), type, &v);
      break;
    }
    case DBUS_TYPE_INT64: {
      dbus_int64_t v = (dbus_int64_t)n;
      ok = dbus_message_iter_append_basic(Iter_val(_iter), type, &v);
      break;
    }
    case DBUS_TYPE_UINT64: {
      dbus_uint64_t v = (dbus_uint64_t)n;
      ok = dbus_message_iter_append_basic(Iter_val(_iter), type, &v);
      break;
    }
    default:
      caml_failwith("dbus: not an integer type");
  }
  if (!ok)
    caml_failwith("dbus: out of memory appending");
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_dbus_iter_append_double(value _iter, value _v) {
  CAMLparam2(_iter, _v);
  double v = Double_val(_v);
  if (!dbus_message_iter_append_basic(Iter_val(_iter), DBUS_TYPE_DOUBLE, &v))
    caml_failwith("dbus: out of memory appending");
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_dbus_iter_append_string(value _iter, value _type, value _v) {
  CAMLparam3(_iter, _type, _v);
  const char *s = String_val(_v);
  if (!dbus_message_iter_append_basic(Iter_val(_iter), Int_val(_type), &s))
    caml_failwith("dbus: out of memory appending");
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_dbus_iter_arg_type(value _iter) {
  CAMLparam1(_iter);
  CAMLreturn(Val_int(dbus_message_iter_get_arg_type(Iter_val(_iter))));
}

CAMLprim value tsync_dbus_iter_element_signature(value _iter) {
  CAMLparam1(_iter);
  CAMLlocal1(result);
  char *s = dbus_message_iter_get_signature(Iter_val(_iter));
  result = caml_copy_string(s ? s : "");
  if (s)
    dbus_free(s);
  CAMLreturn(result);
}

CAMLprim value tsync_dbus_iter_next(value _iter) {
  CAMLparam1(_iter);
  CAMLreturn(Val_bool(dbus_message_iter_next(Iter_val(_iter))));
}

CAMLprim value tsync_dbus_iter_recurse(value _iter) {
  CAMLparam1(_iter);
  CAMLlocal1(sub);
  sub = tsync_alloc_iter(Iter_handle(_iter)->owner);
  dbus_message_iter_recurse(Iter_val(_iter), Iter_val(sub));
  CAMLreturn(sub);
}

/* Every fixed-size type widened to int64; dbus.ml narrows by the arg type it
 * already had to read to get here. */
CAMLprim value tsync_dbus_iter_get_int(value _iter) {
  CAMLparam1(_iter);
  int64_t out = 0;
  switch (dbus_message_iter_get_arg_type(Iter_val(_iter))) {
    case DBUS_TYPE_BYTE: {
      unsigned char v;
      dbus_message_iter_get_basic(Iter_val(_iter), &v);
      out = v;
      break;
    }
    case DBUS_TYPE_BOOLEAN: {
      dbus_bool_t v;
      dbus_message_iter_get_basic(Iter_val(_iter), &v);
      out = v ? 1 : 0;
      break;
    }
    case DBUS_TYPE_INT16: {
      dbus_int16_t v;
      dbus_message_iter_get_basic(Iter_val(_iter), &v);
      out = v;
      break;
    }
    case DBUS_TYPE_UINT16: {
      dbus_uint16_t v;
      dbus_message_iter_get_basic(Iter_val(_iter), &v);
      out = v;
      break;
    }
    case DBUS_TYPE_INT32: {
      dbus_int32_t v;
      dbus_message_iter_get_basic(Iter_val(_iter), &v);
      out = v;
      break;
    }
    case DBUS_TYPE_UINT32: {
      dbus_uint32_t v;
      dbus_message_iter_get_basic(Iter_val(_iter), &v);
      out = v;
      break;
    }
    case DBUS_TYPE_INT64: {
      dbus_int64_t v;
      dbus_message_iter_get_basic(Iter_val(_iter), &v);
      out = v;
      break;
    }
    case DBUS_TYPE_UINT64: {
      dbus_uint64_t v;
      dbus_message_iter_get_basic(Iter_val(_iter), &v);
      out = (int64_t)v;
      break;
    }
    default:
      caml_failwith("dbus: not an integer type");
  }
  CAMLreturn(caml_copy_int64(out));
}

CAMLprim value tsync_dbus_iter_get_double(value _iter) {
  CAMLparam1(_iter);
  double v = 0.;
  dbus_message_iter_get_basic(Iter_val(_iter), &v);
  CAMLreturn(caml_copy_double(v));
}

CAMLprim value tsync_dbus_iter_get_string(value _iter) {
  CAMLparam1(_iter);
  const char *s = NULL;
  dbus_message_iter_get_basic(Iter_val(_iter), &s);
  CAMLreturn(caml_copy_string(s ? s : ""));
}
