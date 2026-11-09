/* Network.framework connections for Http_apple (security-model §9.1, a
   platform connection). Every call returns at once: Network.framework answers
   on a serial queue of the connection's own, whose handlers store their result
   under the connection's mutex and write one byte to its wake pipe, which the
   OCaml side waits on. The handlers never touch the OCaml runtime. */

#include <Network/Network.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

enum connection_state { CONNECTING, READY, FAILED, CLOSED };

enum failure_kind { NO_FAILURE, UNTRUSTED, BROKEN };

typedef struct apple_connection {
  nw_connection_t handle;
  dispatch_queue_t queue;
  pthread_mutex_t mutex;
  int wake_read;
  int wake_write;
  /* One reference for the OCaml value, one for Network.framework's handlers,
     dropped when the connection reaches its cancelled state. */
  atomic_int references;
  enum connection_state state;
  enum failure_kind failure;
  char reason[256];
  dispatch_data_t received;
  int receiving;
  int end_of_stream;
  int sending;
  int cancelled;
  /* What the verify block reads, alive as long as the connection. */
  CFArrayRef anchors;
  CFStringRef server_name;
  /* Why the verify block refused, which the handshake failure then reports
     instead of Network.framework's generic code. */
  char refusal[256];
} apple_connection;

static void wake(apple_connection *connection) {
  char byte = 1;
  while (write(connection->wake_write, &byte, 1) < 0 && errno == EINTR)
    ;
}

static void release(apple_connection *connection) {
  if (atomic_fetch_sub(&connection->references, 1) != 1)
    return;
  if (connection->received)
    dispatch_release(connection->received);
  if (connection->anchors)
    CFRelease(connection->anchors);
  if (connection->server_name)
    CFRelease(connection->server_name);
  nw_release(connection->handle);
  dispatch_release(connection->queue);
  close(connection->wake_read);
  close(connection->wake_write);
  pthread_mutex_destroy(&connection->mutex);
  free(connection);
}

/* Only a certificate the platform refused is untrusted; any other failure is
   one a retry may not meet (security-model §9.1). */
static int is_certificate_status(OSStatus status) {
  switch (status) {
  case errSSLXCertChainInvalid:
  case errSSLBadCert:
  case errSSLUnknownRootCert:
  case errSSLNoRootCert:
  case errSSLCertExpired:
  case errSSLCertNotYetValid:
  case errSSLPeerBadCert:
  case errSSLPeerCertExpired:
  case errSSLPeerCertRevoked:
  case errSSLPeerCertUnknown:
  case errSSLPeerUnknownCA:
  case errSSLHostNameMismatch:
    return 1;
  default:
    return 0;
  }
}

static void record_failure(apple_connection *connection, nw_error_t error,
                           const char *what) {
  if (connection->failure != NO_FAILURE)
    return;
  connection->failure = BROKEN;
  if (error == NULL) {
    snprintf(connection->reason, sizeof connection->reason, "%s", what);
    return;
  }
  int code = nw_error_get_error_code(error);
  if (nw_error_get_error_domain(error) == nw_error_domain_tls) {
    if (is_certificate_status(code))
      connection->failure = UNTRUSTED;
    if (connection->refusal[0]) {
      snprintf(connection->reason, sizeof connection->reason, "%s", connection->refusal);
      return;
    }
    CFStringRef message = SecCopyErrorMessageString(code, NULL);
    char text[200] = "";
    if (message) {
      CFStringGetCString(message, text, sizeof text, kCFStringEncodingUTF8);
      CFRelease(message);
    }
    snprintf(connection->reason, sizeof connection->reason, "%s (%d)",
             text[0] ? text : "TLS failure", code);
  } else
    snprintf(connection->reason, sizeof connection->reason, "%s", strerror(code));
}

static void on_state(apple_connection *connection, nw_connection_state_t state,
                     nw_error_t error) {
  pthread_mutex_lock(&connection->mutex);
  switch (state) {
  case nw_connection_state_ready:
    if (connection->state == CONNECTING)
      connection->state = READY;
    break;
  /* Waiting is Network.framework retrying by itself, which is the core's
     ladder to decide (01 §7). */
  case nw_connection_state_waiting:
  case nw_connection_state_failed:
    record_failure(connection, error, "the connection failed");
    connection->state = FAILED;
    break;
  case nw_connection_state_cancelled:
    if (connection->state != CLOSED)
      connection->state = FAILED;
    record_failure(connection, NULL, "the connection was cancelled");
    break;
  default:
    break;
  }
  pthread_mutex_unlock(&connection->mutex);
  wake(connection);
  if (state == nw_connection_state_cancelled)
    release(connection);
}

/* A DER that does not parse is left out; no anchor at all refuses every
   certificate. */
static CFArrayRef anchors_of(value _anchors) {
  CFMutableArrayRef anchors =
      CFArrayCreateMutable(NULL, Wosize_val(_anchors), &kCFTypeArrayCallBacks);
  for (mlsize_t i = 0; i < Wosize_val(_anchors); i++) {
    value _der = Field(_anchors, i);
    CFDataRef der = CFDataCreate(NULL, (const UInt8 *)String_val(_der),
                                 caml_string_length(_der));
    SecCertificateRef certificate = SecCertificateCreateWithData(NULL, der);
    CFRelease(der);
    if (certificate) {
      CFArrayAppendValue(anchors, certificate);
      CFRelease(certificate);
    }
  }
  return anchors;
}

/* With anchors, the chain must end at one of them and the system store is not
   consulted; the name is checked either way. */
static void configure_tls(sec_protocol_options_t options, apple_connection *connection,
                          const char *server_name) {
  sec_protocol_options_set_tls_server_name(options, server_name);
  sec_protocol_options_set_min_tls_protocol_version(options,
                                                    tls_protocol_version_TLSv12);
  /* Network.framework resumes a TLS 1.2 session by host and port, under any
     server name and without the verify block, so a resumed session would skip
     the name check. */
  sec_protocol_options_set_tls_resumption_enabled(options, false);
  if (connection->anchors == NULL)
    return;
  sec_protocol_options_set_verify_block(
      options,
      ^(sec_protocol_metadata_t metadata, sec_trust_t trust_ref,
        sec_protocol_verify_complete_t complete) {
        (void)metadata;
        SecTrustRef trust = sec_trust_copy_ref(trust_ref);
        SecPolicyRef policy = SecPolicyCreateSSL(true, connection->server_name);
        SecTrustSetPolicies(trust, policy);
        SecTrustSetAnchorCertificates(trust, connection->anchors);
        SecTrustSetAnchorCertificatesOnly(trust, true);
        CFErrorRef refusal = NULL;
        bool trusted = SecTrustEvaluateWithError(trust, &refusal);
        if (refusal) {
          CFStringRef text = CFErrorCopyDescription(refusal);
          pthread_mutex_lock(&connection->mutex);
          if (text == NULL ||
              !CFStringGetCString(text, connection->refusal, sizeof connection->refusal,
                                  kCFStringEncodingUTF8))
            snprintf(connection->refusal, sizeof connection->refusal,
                     "the certificate is not trusted");
          pthread_mutex_unlock(&connection->mutex);
          if (text)
            CFRelease(text);
          CFRelease(refusal);
        }
        CFRelease(policy);
        CFRelease(trust);
        complete(trusted);
      },
      connection->queue);
}

static void finalize_connection(value _connection) {
  apple_connection *connection = *(apple_connection **)Data_custom_val(_connection);
  if (connection == NULL)
    return;
  *(apple_connection **)Data_custom_val(_connection) = NULL;
  pthread_mutex_lock(&connection->mutex);
  int cancelled = connection->cancelled;
  connection->cancelled = 1;
  connection->state = CLOSED;
  pthread_mutex_unlock(&connection->mutex);
  if (!cancelled)
    nw_connection_cancel(connection->handle);
  release(connection);
}

static struct custom_operations connection_operations = {
    "tsync.http_apple.connection", finalize_connection,
    custom_compare_default,        custom_hash_default,
    custom_serialize_default,      custom_deserialize_default,
    custom_compare_ext_default,    custom_fixed_length_default};

static apple_connection *connection_val(value _connection) {
  apple_connection *connection = *(apple_connection **)Data_custom_val(_connection);
  if (connection == NULL)
    caml_failwith("http_apple: the connection is closed");
  return connection;
}

value tsync_http_apple_open(value _host, value _port, value _server_name,
                            value _anchors) {
  CAMLparam4(_host, _port, _server_name, _anchors);
  CAMLlocal1(_connection);
  apple_connection *connection = calloc(1, sizeof *connection);
  int wake_pipe[2];
  if (connection == NULL || pipe(wake_pipe) != 0) {
    free(connection);
    caml_failwith("http_apple: no memory or descriptors for a connection");
  }
  for (int i = 0; i < 2; i++) {
    fcntl(wake_pipe[i], F_SETFL, fcntl(wake_pipe[i], F_GETFL) | O_NONBLOCK);
    fcntl(wake_pipe[i], F_SETFD, FD_CLOEXEC);
  }
  connection->wake_read = wake_pipe[0];
  connection->wake_write = wake_pipe[1];
  pthread_mutex_init(&connection->mutex, NULL);
  atomic_init(&connection->references, 2);
  connection->queue = dispatch_queue_create("tsync.http", DISPATCH_QUEUE_SERIAL);

  char port[16];
  snprintf(port, sizeof port, "%ld", Long_val(_port));
  char *server_name = strdup(String_val(_server_name));
  connection->server_name =
      CFStringCreateWithCString(NULL, server_name, kCFStringEncodingUTF8);
  if (Is_some(_anchors))
    connection->anchors = anchors_of(Some_val(_anchors));
  __block int configured = 0;
  nw_parameters_t parameters = nw_parameters_create_secure_tcp(
      ^(nw_protocol_options_t tls) {
        sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tls);
        configure_tls(options, connection, server_name);
        nw_release(options);
        configured = 1;
      },
      ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_no_delay(tcp, true);
      });
  nw_endpoint_t endpoint = nw_endpoint_create_host(String_val(_host), port);
  connection->handle = nw_connection_create(endpoint, parameters);
  nw_release(endpoint);
  nw_release(parameters);
  free(server_name);
  if (!configured) {
    /* No handler holds the second reference: the connection never started. */
    atomic_store(&connection->references, 1);
    release(connection);
    caml_failwith("TLS options were not configured synchronously");
  }

  nw_connection_set_queue(connection->handle, connection->queue);
  nw_connection_set_state_changed_handler(
      connection->handle, ^(nw_connection_state_t state, nw_error_t error) {
        on_state(connection, state, error);
      });
  nw_connection_start(connection->handle);
  _connection = caml_alloc_custom(&connection_operations, sizeof(apple_connection *), 0, 1);
  *(apple_connection **)Data_custom_val(_connection) = connection;
  CAMLreturn(_connection);
}

value tsync_http_apple_wake_fd(value _connection) {
  return Val_int(connection_val(_connection)->wake_read);
}

/* 0 connecting, 1 ready, 2 untrusted, 3 failed. */
static int status_of(apple_connection *connection) {
  if (connection->failure == UNTRUSTED)
    return 2;
  if (connection->state == READY)
    return 1;
  if (connection->state == CONNECTING)
    return 0;
  return 3;
}

value tsync_http_apple_status(value _connection) {
  apple_connection *connection = connection_val(_connection);
  pthread_mutex_lock(&connection->mutex);
  int status = status_of(connection);
  pthread_mutex_unlock(&connection->mutex);
  return Val_int(status);
}

value tsync_http_apple_reason(value _connection) {
  CAMLparam1(_connection);
  apple_connection *connection = connection_val(_connection);
  char reason[sizeof connection->reason];
  pthread_mutex_lock(&connection->mutex);
  memcpy(reason, connection->reason, sizeof reason);
  pthread_mutex_unlock(&connection->mutex);
  CAMLreturn(caml_copy_string(reason));
}

static void receive_more(apple_connection *connection) {
  connection->receiving = 1;
  nw_connection_receive(
      connection->handle, 1, 65536,
      ^(dispatch_data_t content, nw_content_context_t context, bool complete,
        nw_error_t error) {
        (void)context;
        pthread_mutex_lock(&connection->mutex);
        connection->receiving = 0;
        if (content) {
          if (connection->received) {
            dispatch_data_t joined =
                dispatch_data_create_concat(connection->received, content);
            dispatch_release(connection->received);
            connection->received = joined;
          } else {
            dispatch_retain(content);
            connection->received = content;
          }
        }
        if (error)
          record_failure(connection, error, "receive failed");
        else if (complete)
          connection->end_of_stream = 1;
        pthread_mutex_unlock(&connection->mutex);
        wake(connection);
      });
}

/* Bytes copied, 0 at end of stream, -1 when none have arrived yet, -2 after a
   failure. */
value tsync_http_apple_receive(value _connection, value _buffer, value _offset,
                               value _length) {
  apple_connection *connection = connection_val(_connection);
  char *destination = (char *)Caml_ba_data_val(_buffer) + Long_val(_offset);
  size_t wanted = Long_val(_length);
  long result;
  pthread_mutex_lock(&connection->mutex);
  size_t available = connection->received ? dispatch_data_get_size(connection->received) : 0;
  if (available > 0) {
    size_t copy_length = available < wanted ? available : wanted;
    __block size_t copied = 0;
    dispatch_data_apply(connection->received,
                        ^bool(dispatch_data_t region, size_t offset,
                              const void *bytes, size_t size) {
                          (void)region;
                          (void)offset;
                          size_t take = size < copy_length - copied
                                            ? size
                                            : copy_length - copied;
                          memcpy(destination + copied, bytes, take);
                          copied += take;
                          return copied < copy_length;
                        });
    dispatch_data_t rest =
        dispatch_data_create_subrange(connection->received, copy_length,
                                      available - copy_length);
    dispatch_release(connection->received);
    connection->received = rest;
    result = copy_length;
  } else if (connection->end_of_stream)
    result = 0;
  else if (connection->failure != NO_FAILURE || connection->state != READY)
    result = -2;
  else {
    if (!connection->receiving)
      receive_more(connection);
    result = -1;
  }
  pthread_mutex_unlock(&connection->mutex);
  return Val_long(result);
}

/* Starts sending one slice, copied, when none is in flight: 1 when it started,
   0 while another is in flight, -1 after a failure. */
value tsync_http_apple_send(value _connection, value _buffer, value _offset,
                            value _length) {
  apple_connection *connection = connection_val(_connection);
  pthread_mutex_lock(&connection->mutex);
  int started;
  if (connection->failure != NO_FAILURE || connection->state != READY)
    started = -1;
  else if (connection->sending)
    started = 0;
  else {
    dispatch_data_t data = dispatch_data_create(
        (char *)Caml_ba_data_val(_buffer) + Long_val(_offset), Long_val(_length),
        connection->queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    connection->sending = 1;
    started = 1;
    nw_connection_send(connection->handle, data,
                       NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false,
                       ^(nw_error_t error) {
                         pthread_mutex_lock(&connection->mutex);
                         connection->sending = 0;
                         if (error)
                           record_failure(connection, error, "send failed");
                         pthread_mutex_unlock(&connection->mutex);
                         wake(connection);
                       });
    dispatch_release(data);
  }
  pthread_mutex_unlock(&connection->mutex);
  return Val_int(started);
}

/* 0 while a slice is in flight, 1 once all are accepted, -1 after a failure. */
value tsync_http_apple_sent(value _connection) {
  apple_connection *connection = connection_val(_connection);
  pthread_mutex_lock(&connection->mutex);
  int sent = connection->failure != NO_FAILURE || connection->state != READY
                 ? -1
                 : (connection->sending ? 0 : 1);
  pthread_mutex_unlock(&connection->mutex);
  return Val_int(sent);
}

value tsync_http_apple_drain(value _connection) {
  apple_connection *connection = connection_val(_connection);
  char bytes[64];
  while (read(connection->wake_read, bytes, sizeof bytes) > 0)
    ;
  return Val_unit;
}

value tsync_http_apple_close(value _connection) {
  finalize_connection(_connection);
  return Val_unit;
}
