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

typedef struct connection {
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
} connection;

static void wake(connection *conn) {
  char byte = 1;
  while (write(conn->wake_write, &byte, 1) < 0 && errno == EINTR)
    ;
}

static void release(connection *conn) {
  if (atomic_fetch_sub(&conn->references, 1) != 1)
    return;
  if (conn->received)
    dispatch_release(conn->received);
  if (conn->anchors)
    CFRelease(conn->anchors);
  if (conn->server_name)
    CFRelease(conn->server_name);
  nw_release(conn->handle);
  dispatch_release(conn->queue);
  close(conn->wake_read);
  close(conn->wake_write);
  pthread_mutex_destroy(&conn->mutex);
  free(conn);
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

static void record_failure(connection *conn, nw_error_t error,
                           const char *what) {
  if (conn->failure != NO_FAILURE)
    return;
  conn->failure = BROKEN;
  if (error == NULL) {
    snprintf(conn->reason, sizeof conn->reason, "%s", what);
    return;
  }
  int code = nw_error_get_error_code(error);
  if (nw_error_get_error_domain(error) == nw_error_domain_tls) {
    if (is_certificate_status(code))
      conn->failure = UNTRUSTED;
    if (conn->refusal[0]) {
      snprintf(conn->reason, sizeof conn->reason, "%s", conn->refusal);
      return;
    }
    CFStringRef message = SecCopyErrorMessageString(code, NULL);
    char text[200] = "";
    if (message) {
      CFStringGetCString(message, text, sizeof text, kCFStringEncodingUTF8);
      CFRelease(message);
    }
    snprintf(conn->reason, sizeof conn->reason, "%s (%d)",
             text[0] ? text : "TLS failure", code);
  } else
    snprintf(conn->reason, sizeof conn->reason, "%s", strerror(code));
}

static void on_state(connection *conn, nw_connection_state_t state,
                     nw_error_t error) {
  pthread_mutex_lock(&conn->mutex);
  switch (state) {
  case nw_connection_state_ready:
    if (conn->state == CONNECTING)
      conn->state = READY;
    break;
  /* Waiting is Network.framework retrying by itself, which is the core's
     ladder to decide (01 §7). */
  case nw_connection_state_waiting:
  case nw_connection_state_failed:
    record_failure(conn, error, "the connection failed");
    conn->state = FAILED;
    break;
  case nw_connection_state_cancelled:
    if (conn->state != CLOSED)
      conn->state = FAILED;
    record_failure(conn, NULL, "the connection was cancelled");
    break;
  default:
    break;
  }
  pthread_mutex_unlock(&conn->mutex);
  wake(conn);
  if (state == nw_connection_state_cancelled)
    release(conn);
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
static void configure_tls(sec_protocol_options_t options, connection *conn,
                          const char *server_name) {
  sec_protocol_options_set_tls_server_name(options, server_name);
  sec_protocol_options_set_min_tls_protocol_version(options,
                                                    tls_protocol_version_TLSv12);
  if (conn->anchors == NULL)
    return;
  sec_protocol_options_set_verify_block(
      options,
      ^(sec_protocol_metadata_t metadata, sec_trust_t trust_ref,
        sec_protocol_verify_complete_t complete) {
        (void)metadata;
        SecTrustRef trust = sec_trust_copy_ref(trust_ref);
        SecPolicyRef policy = SecPolicyCreateSSL(true, conn->server_name);
        SecTrustSetPolicies(trust, policy);
        SecTrustSetAnchorCertificates(trust, conn->anchors);
        SecTrustSetAnchorCertificatesOnly(trust, true);
        CFErrorRef refusal = NULL;
        bool trusted = SecTrustEvaluateWithError(trust, &refusal);
        if (refusal) {
          CFStringRef text = CFErrorCopyDescription(refusal);
          pthread_mutex_lock(&conn->mutex);
          if (text == NULL ||
              !CFStringGetCString(text, conn->refusal, sizeof conn->refusal,
                                  kCFStringEncodingUTF8))
            snprintf(conn->refusal, sizeof conn->refusal,
                     "the certificate is not trusted");
          pthread_mutex_unlock(&conn->mutex);
          if (text)
            CFRelease(text);
          CFRelease(refusal);
        }
        CFRelease(policy);
        CFRelease(trust);
        complete(trusted);
      },
      conn->queue);
}

static void finalize_connection(value _conn) {
  connection *conn = *(connection **)Data_custom_val(_conn);
  if (conn == NULL)
    return;
  *(connection **)Data_custom_val(_conn) = NULL;
  pthread_mutex_lock(&conn->mutex);
  int cancelled = conn->cancelled;
  conn->cancelled = 1;
  conn->state = CLOSED;
  pthread_mutex_unlock(&conn->mutex);
  if (!cancelled)
    nw_connection_cancel(conn->handle);
  release(conn);
}

static struct custom_operations connection_operations = {
    "tsync.http_apple.connection", finalize_connection,
    custom_compare_default,        custom_hash_default,
    custom_serialize_default,      custom_deserialize_default,
    custom_compare_ext_default,    custom_fixed_length_default};

static connection *connection_val(value _conn) {
  connection *conn = *(connection **)Data_custom_val(_conn);
  if (conn == NULL)
    caml_failwith("http_apple: the connection is closed");
  return conn;
}

value tsync_http_apple_open(value _host, value _port, value _server_name,
                            value _anchors) {
  CAMLparam4(_host, _port, _server_name, _anchors);
  CAMLlocal1(_conn);
  connection *conn = calloc(1, sizeof *conn);
  int wake_pipe[2];
  if (conn == NULL || pipe(wake_pipe) != 0) {
    free(conn);
    caml_failwith("http_apple: no memory or descriptors for a connection");
  }
  for (int i = 0; i < 2; i++) {
    fcntl(wake_pipe[i], F_SETFL, fcntl(wake_pipe[i], F_GETFL) | O_NONBLOCK);
    fcntl(wake_pipe[i], F_SETFD, FD_CLOEXEC);
  }
  conn->wake_read = wake_pipe[0];
  conn->wake_write = wake_pipe[1];
  pthread_mutex_init(&conn->mutex, NULL);
  atomic_init(&conn->references, 2);
  conn->queue = dispatch_queue_create("tsync.http", DISPATCH_QUEUE_SERIAL);

  char port[16];
  snprintf(port, sizeof port, "%ld", Long_val(_port));
  char *server_name = strdup(String_val(_server_name));
  conn->server_name =
      CFStringCreateWithCString(NULL, server_name, kCFStringEncodingUTF8);
  if (Is_some(_anchors))
    conn->anchors = anchors_of(Some_val(_anchors));
  __block int configured = 0;
  nw_parameters_t parameters = nw_parameters_create_secure_tcp(
      ^(nw_protocol_options_t tls) {
        sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tls);
        configure_tls(options, conn, server_name);
        nw_release(options);
        configured = 1;
      },
      ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_no_delay(tcp, true);
      });
  nw_endpoint_t endpoint = nw_endpoint_create_host(String_val(_host), port);
  conn->handle = nw_connection_create(endpoint, parameters);
  nw_release(endpoint);
  nw_release(parameters);
  free(server_name);
  if (!configured)
    caml_failwith("http_apple: TLS options were not configured synchronously");

  nw_connection_set_queue(conn->handle, conn->queue);
  nw_connection_set_state_changed_handler(
      conn->handle, ^(nw_connection_state_t state, nw_error_t error) {
        on_state(conn, state, error);
      });
  nw_connection_start(conn->handle);
  _conn = caml_alloc_custom(&connection_operations, sizeof(connection *), 0, 1);
  *(connection **)Data_custom_val(_conn) = conn;
  CAMLreturn(_conn);
}

value tsync_http_apple_wake_fd(value _conn) {
  return Val_int(connection_val(_conn)->wake_read);
}

/* 0 connecting, 1 ready, 2 untrusted, 3 failed. */
static int status_of(connection *conn) {
  if (conn->failure == UNTRUSTED)
    return 2;
  if (conn->state == READY)
    return 1;
  if (conn->state == CONNECTING)
    return 0;
  return 3;
}

value tsync_http_apple_status(value _conn) {
  connection *conn = connection_val(_conn);
  pthread_mutex_lock(&conn->mutex);
  int status = status_of(conn);
  pthread_mutex_unlock(&conn->mutex);
  return Val_int(status);
}

value tsync_http_apple_reason(value _conn) {
  CAMLparam1(_conn);
  connection *conn = connection_val(_conn);
  char reason[sizeof conn->reason];
  pthread_mutex_lock(&conn->mutex);
  memcpy(reason, conn->reason, sizeof reason);
  pthread_mutex_unlock(&conn->mutex);
  CAMLreturn(caml_copy_string(reason));
}

static void receive_more(connection *conn) {
  conn->receiving = 1;
  nw_connection_receive(
      conn->handle, 1, 65536,
      ^(dispatch_data_t content, nw_content_context_t context, bool complete,
        nw_error_t error) {
        (void)context;
        pthread_mutex_lock(&conn->mutex);
        conn->receiving = 0;
        if (content) {
          if (conn->received) {
            dispatch_data_t joined =
                dispatch_data_create_concat(conn->received, content);
            dispatch_release(conn->received);
            conn->received = joined;
          } else {
            dispatch_retain(content);
            conn->received = content;
          }
        }
        if (error)
          record_failure(conn, error, "receive failed");
        else if (complete)
          conn->end_of_stream = 1;
        pthread_mutex_unlock(&conn->mutex);
        wake(conn);
      });
}

/* Bytes copied, 0 at end of stream, -1 when none have arrived yet, -2 after a
   failure. */
value tsync_http_apple_receive(value _conn, value _buffer, value _off,
                               value _len) {
  connection *conn = connection_val(_conn);
  char *dst = (char *)Caml_ba_data_val(_buffer) + Long_val(_off);
  size_t wanted = Long_val(_len);
  long result;
  pthread_mutex_lock(&conn->mutex);
  size_t available = conn->received ? dispatch_data_get_size(conn->received) : 0;
  if (available > 0) {
    size_t n = available < wanted ? available : wanted;
    __block size_t copied = 0;
    dispatch_data_apply(conn->received,
                        ^bool(dispatch_data_t region, size_t offset,
                              const void *bytes, size_t size) {
                          (void)region;
                          (void)offset;
                          size_t take = size < n - copied ? size : n - copied;
                          memcpy(dst + copied, bytes, take);
                          copied += take;
                          return copied < n;
                        });
    dispatch_data_t rest =
        dispatch_data_create_subrange(conn->received, n, available - n);
    dispatch_release(conn->received);
    conn->received = rest;
    result = n;
  } else if (conn->end_of_stream)
    result = 0;
  else if (conn->failure != NO_FAILURE || conn->state != READY)
    result = -2;
  else {
    if (!conn->receiving)
      receive_more(conn);
    result = -1;
  }
  pthread_mutex_unlock(&conn->mutex);
  return Val_long(result);
}

/* Starts sending one slice, copied, when none is in flight: answers whether it
   started. */
value tsync_http_apple_send(value _conn, value _buffer, value _off,
                            value _len) {
  connection *conn = connection_val(_conn);
  pthread_mutex_lock(&conn->mutex);
  int started = 0;
  if (!conn->sending && conn->state == READY && conn->failure == NO_FAILURE) {
    dispatch_data_t data = dispatch_data_create(
        (char *)Caml_ba_data_val(_buffer) + Long_val(_off), Long_val(_len),
        conn->queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    conn->sending = 1;
    started = 1;
    nw_connection_send(conn->handle, data,
                       NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false,
                       ^(nw_error_t error) {
                         pthread_mutex_lock(&conn->mutex);
                         conn->sending = 0;
                         if (error)
                           record_failure(conn, error, "send failed");
                         pthread_mutex_unlock(&conn->mutex);
                         wake(conn);
                       });
    dispatch_release(data);
  }
  pthread_mutex_unlock(&conn->mutex);
  return Val_bool(started);
}

/* 0 while a slice is in flight, 1 once all are accepted, -1 after a failure. */
value tsync_http_apple_sent(value _conn) {
  connection *conn = connection_val(_conn);
  pthread_mutex_lock(&conn->mutex);
  int sent = conn->failure != NO_FAILURE || conn->state != READY
                 ? -1
                 : (conn->sending ? 0 : 1);
  pthread_mutex_unlock(&conn->mutex);
  return Val_int(sent);
}

value tsync_http_apple_drain(value _conn) {
  connection *conn = connection_val(_conn);
  char bytes[64];
  while (read(conn->wake_read, bytes, sizeof bytes) > 0)
    ;
  return Val_unit;
}

value tsync_http_apple_close(value _conn) {
  finalize_connection(_conn);
  return Val_unit;
}
