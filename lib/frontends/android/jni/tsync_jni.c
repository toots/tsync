/* JNI marshalling only: every call is tsync_bridge.h's. Text crosses as byte
   arrays, since a jstring is modified UTF-8 and cannot carry every name. */
#define CAML_NAME_SPACE
#include <android/log.h>
#include <errno.h>
#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "tsync_bridge.h"

CAMLprim value tsync_log_write(value _level, value _message) {
  static const int priorities[] = {ANDROID_LOG_DEBUG, ANDROID_LOG_INFO,
                                   ANDROID_LOG_WARN, ANDROID_LOG_ERROR};
  __android_log_write(priorities[Int_val(_level)], "tsync",
                      String_val(_message));
  return Val_unit;
}

static char *copy_bytes(JNIEnv *env, jbyteArray array, size_t *length) {
  *length = (*env)->GetArrayLength(env, array);
  char *bytes = malloc(*length + 1);
  if (bytes == NULL)
    abort();
  (*env)->GetByteArrayRegion(env, array, 0, *length, (jbyte *)bytes);
  bytes[*length] = 0;
  return bytes;
}

static jbyteArray to_array(JNIEnv *env, const char *bytes, size_t length) {
  jbyteArray array = (*env)->NewByteArray(env, length);
  if (array != NULL)
    (*env)->SetByteArrayRegion(env, array, 0, length, (const jbyte *)bytes);
  return array;
}

static jbyteArray text_call(JNIEnv *env, const char *name, jbyteArray arg) {
  static const char not_started[] = "the core is not initialised";
  size_t arg_length = 0, length = 0;
  char *bytes = arg == NULL ? NULL : copy_bytes(env, arg, &arg_length);
  char *text = tsync_bridge_text(name, bytes == NULL ? "" : bytes, arg_length,
                                 &length);
  free(bytes);
  if (text == NULL)
    return to_array(env, not_started, sizeof not_started - 1);
  jbyteArray result = to_array(env, text, length);
  free(text);
  return result;
}

/* Module initialisers derive every path from HOME as they run, so the
   environment is set before the runtime starts. */
static pthread_mutex_t start_lock = PTHREAD_MUTEX_INITIALIZER;
static int runtime_started;

JNIEXPORT void JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeInit(JNIEnv *env, jclass class,
                                                     jbyteArray home,
                                                     jbyteArray trust_store,
                                                     jbyteArray transfer_root) {
  size_t length;
  pthread_mutex_lock(&start_lock);
  if (!runtime_started) {
    char *home_path = copy_bytes(env, home, &length);
    char *trust_store_path = copy_bytes(env, trust_store, &length);
    char *transfer_root_path = copy_bytes(env, transfer_root, &length);
    setenv("HOME", home_path, 1);
    setenv("SSL_CERT_FILE", trust_store_path, 1);
    char *argv[] = {"tsync", NULL};
    caml_startup(argv);
    tsync_bridge_started();
    caml_release_runtime_system();
    tsync_bridge_init(trust_store_path, transfer_root_path);
    free(home_path);
    free(trust_store_path);
    free(transfer_root_path);
    runtime_started = 1;
  }
  pthread_mutex_unlock(&start_lock);
}

/* An empty text is success, which the host reads as null. */
static jbyteArray error_or_null(JNIEnv *env, const char *name,
                                jbyteArray arg) {
  jbyteArray text = text_call(env, name, arg);
  return text != NULL && (*env)->GetArrayLength(env, text) == 0 ? NULL : text;
}

/* candidate: the config text to check in place of the config, or null. */
JNIEXPORT jbyteArray JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeCheckConfig(
    JNIEnv *env, jclass class, jbyteArray domain, jbyteArray candidate) {
  static const char not_started[] = "the core is not initialised";
  size_t domain_length, candidate_length = 0, length = 0;
  char *domain_bytes = copy_bytes(env, domain, &domain_length);
  char *candidate_bytes =
      candidate == NULL ? NULL : copy_bytes(env, candidate, &candidate_length);
  size_t arg_length =
      domain_length + (candidate == NULL ? 0 : 1 + candidate_length);
  char *arg = malloc(arg_length + 1);
  if (arg == NULL)
    abort();
  memcpy(arg, domain_bytes, domain_length + 1);
  if (candidate_bytes != NULL)
    memcpy(arg + domain_length + 1, candidate_bytes, candidate_length);
  char *text = tsync_bridge_text("check_config", arg, arg_length, &length);
  free(arg);
  free(domain_bytes);
  free(candidate_bytes);
  if (text == NULL)
    return to_array(env, not_started, sizeof not_started - 1);
  jbyteArray result = length == 0 ? NULL : to_array(env, text, length);
  free(text);
  return result;
}

JNIEXPORT jbyteArray JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeBoot(JNIEnv *env, jclass class,
                                                     jbyteArray domain) {
  return error_or_null(env, "boot", domain);
}

JNIEXPORT jbyteArray JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeRequest(JNIEnv *env,
                                                        jclass class,
                                                        jbyteArray json) {
  return text_call(env, "request", json);
}

JNIEXPORT jbyteArray JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeStatus(JNIEnv *env,
                                                       jclass class) {
  return text_call(env, "status", NULL);
}

JNIEXPORT jbyteArray JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeNextNotice(JNIEnv *env,
                                                           jclass class) {
  return text_call(env, "next_notice", NULL);
}

JNIEXPORT jlong JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeOpen(JNIEnv *env, jclass class,
                                                     jbyteArray ref) {
  size_t length;
  char *bytes = copy_bytes(env, ref, &length);
  long handle = tsync_bridge_open(bytes, length);
  free(bytes);
  return handle;
}

JNIEXPORT jlong JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeSize(JNIEnv *env, jclass class,
                                                     jlong handle) {
  return tsync_bridge_size(handle);
}

/* Not a critical region: it would stall the JVM's collector for as long as a
   network read takes. */
JNIEXPORT jint JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeRead(JNIEnv *env, jclass class,
                                                     jlong handle, jlong offset,
                                                     jint length,
                                                     jbyteArray dest) {
  if (length < 0 || length > (*env)->GetArrayLength(env, dest))
    return -EINVAL;
  char *buffer = malloc(length > 0 ? length : 1);
  if (buffer == NULL)
    return -ENOMEM;
  long served = tsync_bridge_read(handle, offset, length, buffer);
  if (served > 0)
    (*env)->SetByteArrayRegion(env, dest, 0, served, (const jbyte *)buffer);
  free(buffer);
  return served;
}

JNIEXPORT jint JNICALL
Java_org_feverdreamtv_tsync_bridge_Native_nativeClose(JNIEnv *env, jclass class,
                                                      jlong handle) {
  return tsync_bridge_close(handle);
}
