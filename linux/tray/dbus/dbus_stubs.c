#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <dbus/dbus.h>
#include <string.h>

/* The constructors of Dbus.value that carry arguments, in declaration order. */
enum {
  TAG_BYTE,
  TAG_BOOL,
  TAG_INT32,
  TAG_UINT32,
  TAG_INT64,
  TAG_DOUBLE,
  TAG_STRING,
  TAG_OBJECT_PATH,
  TAG_SIGNATURE,
  TAG_ARRAY,
  TAG_STRUCT,
  TAG_VARIANT,
  TAG_DICT_ENTRY
};

#define SIGNATURE_MAX 256

static void raise_error(const char *text) {
  caml_raise_with_string(*caml_named_value("tsync_dbus_error"), text);
}

#define Message_val(_message) (*(DBusMessage **)Data_custom_val(_message))
#define Connection_val(_connection)                                            \
  (*(DBusConnection **)Data_custom_val(_connection))

static void finalize_message(value _message) {
  DBusMessage *message = Message_val(_message);
  if (message != NULL)
    dbus_message_unref(message);
}

static struct custom_operations message_operations = {
    "tsync.dbus.message",       finalize_message,
    custom_compare_default,     custom_hash_default,
    custom_serialize_default,   custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

/* A connection lives as long as the process: closing it from a finaliser
   could run on any thread. */
static struct custom_operations connection_operations = {
    "tsync.dbus.connection",    custom_finalize_default,
    custom_compare_default,     custom_hash_default,
    custom_serialize_default,   custom_deserialize_default,
    custom_compare_ext_default, custom_fixed_length_default};

static value wrap_message(DBusMessage *message) {
  if (message == NULL)
    raise_error("libdbus refused the message");
  value _message =
      caml_alloc_custom(&message_operations, sizeof(DBusMessage *), 0, 1);
  Message_val(_message) = message;
  return _message;
}

static value copy_header(const char *field) {
  return caml_copy_string(field == NULL ? "" : field);
}

CAMLprim value tsync_dbus_message_kind(value _message) {
  switch (dbus_message_get_type(Message_val(_message))) {
  case DBUS_MESSAGE_TYPE_METHOD_CALL:
    return Val_int(0);
  case DBUS_MESSAGE_TYPE_METHOD_RETURN:
    return Val_int(1);
  case DBUS_MESSAGE_TYPE_ERROR:
    return Val_int(2);
  default:
    return Val_int(3);
  }
}

CAMLprim value tsync_dbus_message_path(value _message) {
  return copy_header(dbus_message_get_path(Message_val(_message)));
}

CAMLprim value tsync_dbus_message_interface(value _message) {
  return copy_header(dbus_message_get_interface(Message_val(_message)));
}

CAMLprim value tsync_dbus_message_member(value _message) {
  return copy_header(dbus_message_get_member(Message_val(_message)));
}

CAMLprim value tsync_dbus_message_error_name(value _message) {
  return copy_header(dbus_message_get_error_name(Message_val(_message)));
}

CAMLprim value tsync_dbus_message_reply_serial(value _message) {
  return Val_long(dbus_message_get_reply_serial(Message_val(_message)));
}

CAMLprim value tsync_dbus_message_no_reply(value _message) {
  return Val_bool(dbus_message_get_no_reply(Message_val(_message)));
}

static value read_elements(DBusMessageIter *iterator);

static value tagged(int tag, value _argument) {
  CAMLparam1(_argument);
  CAMLlocal1(_result);
  _result = caml_alloc(1, tag);
  Store_field(_result, 0, _argument);
  CAMLreturn(_result);
}

static value read_element(DBusMessageIter *iterator) {
  CAMLparam0();
  CAMLlocal3(_result, _first, _second);
  DBusBasicValue basic;
  DBusMessageIter children;
  int type = dbus_message_iter_get_arg_type(iterator);
  switch (type) {
  case DBUS_TYPE_BYTE:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(TAG_BYTE, Val_int(basic.byt)));
  case DBUS_TYPE_BOOLEAN:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(TAG_BOOL, Val_bool(basic.bool_val)));
  case DBUS_TYPE_INT16:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(TAG_INT32, Val_long(basic.i16)));
  case DBUS_TYPE_INT32:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(TAG_INT32, Val_long(basic.i32)));
  case DBUS_TYPE_UINT16:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(TAG_UINT32, Val_long(basic.u16)));
  case DBUS_TYPE_UINT32:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(TAG_UINT32, Val_long(basic.u32)));
  case DBUS_TYPE_INT64:
  case DBUS_TYPE_UINT64:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(TAG_INT64, Val_long(basic.i64)));
  case DBUS_TYPE_DOUBLE:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(TAG_DOUBLE, caml_copy_double(basic.dbl)));
  case DBUS_TYPE_STRING:
  case DBUS_TYPE_OBJECT_PATH:
  case DBUS_TYPE_SIGNATURE:
    dbus_message_iter_get_basic(iterator, &basic);
    CAMLreturn(tagged(type == DBUS_TYPE_STRING        ? TAG_STRING
                      : type == DBUS_TYPE_OBJECT_PATH ? TAG_OBJECT_PATH
                                                      : TAG_SIGNATURE,
                      caml_copy_string(basic.str)));
  case DBUS_TYPE_ARRAY: {
    char *signature = dbus_message_iter_get_signature(iterator);
    if (signature == NULL)
      caml_raise_out_of_memory();
    _first = caml_copy_string(signature + 1);
    dbus_free(signature);
    dbus_message_iter_recurse(iterator, &children);
    _second = read_elements(&children);
    _result = caml_alloc(2, TAG_ARRAY);
    Store_field(_result, 0, _first);
    Store_field(_result, 1, _second);
    CAMLreturn(_result);
  }
  case DBUS_TYPE_STRUCT:
    dbus_message_iter_recurse(iterator, &children);
    CAMLreturn(tagged(TAG_STRUCT, read_elements(&children)));
  case DBUS_TYPE_VARIANT:
    dbus_message_iter_recurse(iterator, &children);
    CAMLreturn(tagged(TAG_VARIANT, read_element(&children)));
  case DBUS_TYPE_DICT_ENTRY:
    dbus_message_iter_recurse(iterator, &children);
    _first = read_element(&children);
    dbus_message_iter_next(&children);
    _second = read_element(&children);
    _result = caml_alloc(2, TAG_DICT_ENTRY);
    Store_field(_result, 0, _first);
    Store_field(_result, 1, _second);
    CAMLreturn(_result);
  default:
    CAMLreturn(Val_int(0));
  }
}

static value read_elements(DBusMessageIter *iterator) {
  CAMLparam0();
  CAMLlocal4(_list, _last, _cell, _element);
  _list = Val_emptylist;
  while (dbus_message_iter_get_arg_type(iterator) != DBUS_TYPE_INVALID) {
    _element = read_element(iterator);
    _cell = caml_alloc(2, Tag_cons);
    Store_field(_cell, 0, _element);
    Store_field(_cell, 1, Val_emptylist);
    if (_list == Val_emptylist)
      _list = _cell;
    else
      Store_field(_last, 1, _cell);
    _last = _cell;
    dbus_message_iter_next(iterator);
  }
  CAMLreturn(_list);
}

CAMLprim value tsync_dbus_message_body(value _message) {
  CAMLparam1(_message);
  DBusMessageIter iterator;
  if (!dbus_message_iter_init(Message_val(_message), &iterator))
    CAMLreturn(Val_emptylist);
  CAMLreturn(read_elements(&iterator));
}

/* Writes the signature of a value; answers 0 when it does not fit. */
static int write_signature(value _value, char *signature, size_t *used) {
#define PUT(character)                                                         \
  do {                                                                         \
    if (*used + 1 >= SIGNATURE_MAX)                                            \
      return 0;                                                                \
    signature[(*used)++] = (character);                                        \
    signature[*used] = 0;                                                      \
  } while (0)
  if (Is_long(_value))
    return 0;
  switch (Tag_val(_value)) {
  case TAG_BYTE:
    PUT('y');
    return 1;
  case TAG_BOOL:
    PUT('b');
    return 1;
  case TAG_INT32:
    PUT('i');
    return 1;
  case TAG_UINT32:
    PUT('u');
    return 1;
  case TAG_INT64:
    PUT('x');
    return 1;
  case TAG_DOUBLE:
    PUT('d');
    return 1;
  case TAG_STRING:
    PUT('s');
    return 1;
  case TAG_OBJECT_PATH:
    PUT('o');
    return 1;
  case TAG_SIGNATURE:
    PUT('g');
    return 1;
  case TAG_VARIANT:
    PUT('v');
    return 1;
  case TAG_ARRAY: {
    size_t length = caml_string_length(Field(_value, 0));
    if (*used + length + 2 >= SIGNATURE_MAX)
      return 0;
    PUT('a');
    memcpy(signature + *used, String_val(Field(_value, 0)), length);
    *used += length;
    signature[*used] = 0;
    return 1;
  }
  case TAG_STRUCT:
    PUT('(');
    for (value _cell = Field(_value, 0); _cell != Val_emptylist;
         _cell = Field(_cell, 1))
      if (!write_signature(Field(_cell, 0), signature, used))
        return 0;
    PUT(')');
    return 1;
  case TAG_DICT_ENTRY:
    PUT('{');
    if (!write_signature(Field(_value, 0), signature, used) ||
        !write_signature(Field(_value, 1), signature, used))
      return 0;
    PUT('}');
    return 1;
  default:
    return 0;
  }
#undef PUT
}

/* Nothing here allocates on the OCaml heap, so the values are not rooted.
   Answers 0 on a value libdbus refuses or cannot hold. */
static int append_element(DBusMessageIter *iterator, value _value) {
  DBusMessageIter children;
  DBusBasicValue basic;
  if (Is_long(_value))
    return 0;
  switch (Tag_val(_value)) {
  case TAG_BYTE:
    basic.byt = Int_val(Field(_value, 0));
    return dbus_message_iter_append_basic(iterator, DBUS_TYPE_BYTE, &basic);
  case TAG_BOOL:
    basic.bool_val = Bool_val(Field(_value, 0));
    return dbus_message_iter_append_basic(iterator, DBUS_TYPE_BOOLEAN, &basic);
  case TAG_INT32:
    basic.i32 = (dbus_int32_t)Long_val(Field(_value, 0));
    return dbus_message_iter_append_basic(iterator, DBUS_TYPE_INT32, &basic);
  case TAG_UINT32:
    basic.u32 = (dbus_uint32_t)Long_val(Field(_value, 0));
    return dbus_message_iter_append_basic(iterator, DBUS_TYPE_UINT32, &basic);
  case TAG_INT64:
    basic.i64 = Long_val(Field(_value, 0));
    return dbus_message_iter_append_basic(iterator, DBUS_TYPE_INT64, &basic);
  case TAG_DOUBLE:
    basic.dbl = Double_val(Field(_value, 0));
    return dbus_message_iter_append_basic(iterator, DBUS_TYPE_DOUBLE, &basic);
  case TAG_STRING:
  case TAG_OBJECT_PATH:
  case TAG_SIGNATURE: {
    int tag = Tag_val(_value);
    const char *text = String_val(Field(_value, 0));
    if (tag == TAG_OBJECT_PATH && !dbus_validate_path(text, NULL))
      return 0;
    if (tag == TAG_SIGNATURE && !dbus_signature_validate(text, NULL))
      return 0;
    if (tag == TAG_STRING && !dbus_validate_utf8(text, NULL))
      return 0;
    return dbus_message_iter_append_basic(
        iterator,
        tag == TAG_STRING        ? DBUS_TYPE_STRING
        : tag == TAG_OBJECT_PATH ? DBUS_TYPE_OBJECT_PATH
                                 : DBUS_TYPE_SIGNATURE,
        &text);
  }
  case TAG_ARRAY: {
    const char *element_signature = String_val(Field(_value, 0));
    char array_signature[SIGNATURE_MAX];
    size_t array_used = 0;
    if (!write_signature(_value, array_signature, &array_used) ||
        !dbus_signature_validate_single(array_signature, NULL))
      return 0;
    if (!dbus_message_iter_open_container(iterator, DBUS_TYPE_ARRAY,
                                          element_signature, &children))
      return 0;
    for (value _cell = Field(_value, 1); _cell != Val_emptylist;
         _cell = Field(_cell, 1)) {
      char signature[SIGNATURE_MAX];
      size_t used = 0;
      if (!write_signature(Field(_cell, 0), signature, &used) ||
          strcmp(signature, element_signature) != 0 ||
          !append_element(&children, Field(_cell, 0))) {
        dbus_message_iter_abandon_container(iterator, &children);
        return 0;
      }
    }
    return dbus_message_iter_close_container(iterator, &children);
  }
  case TAG_STRUCT: {
    if (Field(_value, 0) == Val_emptylist)
      return 0;
    if (!dbus_message_iter_open_container(iterator, DBUS_TYPE_STRUCT, NULL,
                                          &children))
      return 0;
    for (value _cell = Field(_value, 0); _cell != Val_emptylist;
         _cell = Field(_cell, 1))
      if (!append_element(&children, Field(_cell, 0))) {
        dbus_message_iter_abandon_container(iterator, &children);
        return 0;
      }
    return dbus_message_iter_close_container(iterator, &children);
  }
  case TAG_VARIANT: {
    char signature[SIGNATURE_MAX];
    size_t used = 0;
    if (!write_signature(Field(_value, 0), signature, &used))
      return 0;
    if (!dbus_message_iter_open_container(iterator, DBUS_TYPE_VARIANT,
                                          signature, &children))
      return 0;
    if (!append_element(&children, Field(_value, 0))) {
      dbus_message_iter_abandon_container(iterator, &children);
      return 0;
    }
    return dbus_message_iter_close_container(iterator, &children);
  }
  case TAG_DICT_ENTRY: {
    if (!dbus_message_iter_open_container(iterator, DBUS_TYPE_DICT_ENTRY, NULL,
                                          &children))
      return 0;
    if (!append_element(&children, Field(_value, 0)) ||
        !append_element(&children, Field(_value, 1))) {
      dbus_message_iter_abandon_container(iterator, &children);
      return 0;
    }
    return dbus_message_iter_close_container(iterator, &children);
  }
  default:
    return 0;
  }
}

CAMLprim value tsync_dbus_message_append(value _message, value _values) {
  CAMLparam2(_message, _values);
  DBusMessageIter iterator;
  dbus_message_iter_init_append(Message_val(_message), &iterator);
  for (value _cell = _values; _cell != Val_emptylist; _cell = Field(_cell, 1))
    if (!append_element(&iterator, Field(_cell, 0)))
      raise_error("a value that cannot be sent");
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_dbus_new_method_call(value _destination, value _path,
                                          value _interface, value _member) {
  CAMLparam4(_destination, _path, _interface, _member);
  int no_interface = caml_string_length(_interface) == 0;
  if (!dbus_validate_bus_name(String_val(_destination), NULL) ||
      !dbus_validate_path(String_val(_path), NULL) ||
      (!no_interface && !dbus_validate_interface(String_val(_interface), NULL)) ||
      !dbus_validate_member(String_val(_member), NULL))
    raise_error("an invalid name in a method call");
  CAMLreturn(wrap_message(dbus_message_new_method_call(
      String_val(_destination), String_val(_path),
      no_interface ? NULL : String_val(_interface), String_val(_member))));
}

CAMLprim value tsync_dbus_new_method_return(value _call) {
  CAMLparam1(_call);
  CAMLreturn(wrap_message(dbus_message_new_method_return(Message_val(_call))));
}

CAMLprim value tsync_dbus_new_error(value _call, value _name, value _text) {
  CAMLparam3(_call, _name, _text);
  if (!dbus_validate_error_name(String_val(_name), NULL) ||
      !dbus_validate_utf8(String_val(_text), NULL))
    raise_error("an invalid error reply");
  CAMLreturn(wrap_message(dbus_message_new_error(
      Message_val(_call), String_val(_name), String_val(_text))));
}

CAMLprim value tsync_dbus_new_signal(value _path, value _interface,
                                     value _member) {
  CAMLparam3(_path, _interface, _member);
  if (!dbus_validate_path(String_val(_path), NULL) ||
      !dbus_validate_interface(String_val(_interface), NULL) ||
      !dbus_validate_member(String_val(_member), NULL))
    raise_error("an invalid name in a signal");
  CAMLreturn(wrap_message(dbus_message_new_signal(
      String_val(_path), String_val(_interface), String_val(_member))));
}

CAMLprim value tsync_dbus_connect(value _address) {
  CAMLparam1(_address);
  CAMLlocal1(_connection);
  DBusError error;
  char *address = strdup(String_val(_address));
  if (address == NULL)
    caml_raise_out_of_memory();
  dbus_threads_init_default();
  dbus_error_init(&error);
  caml_release_runtime_system();
  DBusConnection *connection = dbus_connection_open_private(address, &error);
  if (connection != NULL) {
    dbus_connection_set_exit_on_disconnect(connection, FALSE);
    if (!dbus_bus_register(connection, &error)) {
      dbus_connection_close(connection);
      dbus_connection_unref(connection);
      connection = NULL;
    }
  }
  caml_acquire_runtime_system();
  free(address);
  if (connection == NULL) {
    char reason[512];
    strncpy(reason, error.message ? error.message : "connection refused",
            sizeof reason - 1);
    reason[sizeof reason - 1] = 0;
    dbus_error_free(&error);
    raise_error(reason);
  }
  _connection = caml_alloc_custom(&connection_operations,
                                  sizeof(DBusConnection *), 0, 1);
  Connection_val(_connection) = connection;
  CAMLreturn(_connection);
}

static DBusConnection *open_connection(value _connection) {
  DBusConnection *connection = Connection_val(_connection);
  if (connection == NULL)
    raise_error("the connection is closed");
  return connection;
}

CAMLprim value tsync_dbus_descriptor(value _connection) {
  int descriptor = -1;
  if (!dbus_connection_get_unix_fd(open_connection(_connection), &descriptor))
    raise_error("the connection has no descriptor");
  return Val_int(descriptor);
}

CAMLprim value tsync_dbus_send(value _connection, value _message) {
  dbus_uint32_t serial = 0;
  if (!dbus_connection_send(open_connection(_connection),
                            Message_val(_message), &serial))
    caml_raise_out_of_memory();
  return Val_long(serial);
}

CAMLprim value tsync_dbus_read_write(value _connection) {
  return Val_bool(dbus_connection_read_write(open_connection(_connection), 0));
}

CAMLprim value tsync_dbus_pop(value _connection) {
  CAMLparam1(_connection);
  CAMLlocal2(_message, _some);
  DBusMessage *message = dbus_connection_pop_message(open_connection(_connection));
  if (message == NULL)
    CAMLreturn(Val_none);
  _message = wrap_message(message);
  _some = caml_alloc_some(_message);
  CAMLreturn(_some);
}

CAMLprim value tsync_dbus_has_output(value _connection) {
  return Val_bool(
      dbus_connection_has_messages_to_send(open_connection(_connection)));
}

