/* JNI marshalling only: every call is tsync_bridge.h's. Text crosses as byte
   arrays, since a jstring is modified UTF-8 and cannot carry every name. */
#define CAML_NAME_SPACE
#include <android/log.h>
#include <errno.h>
#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/fail.h>
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

/* android §4.1 item 7: the core calls the app's Keystore on its own threads,
   which the JVM must know. Its class is looked up at load: from a native
   thread FindClass only sees the system class loader. */
static JavaVM *java_vm;
static jclass keystore_class;
static jmethodID keystore_put, keystore_get, keystore_delete;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
  JNIEnv *env;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK)
    return JNI_ERR;
  jclass found = (*env)->FindClass(env, "org/feverdreamtv/tsync/bridge/Keystore");
  if (found == NULL)
    return JNI_ERR;
  keystore_class = (*env)->NewGlobalRef(env, found);
  keystore_put = (*env)->GetStaticMethodID(env, keystore_class, "put", "([B[B)V");
  keystore_get = (*env)->GetStaticMethodID(env, keystore_class, "get", "([B)[B");
  keystore_delete =
      (*env)->GetStaticMethodID(env, keystore_class, "delete", "([B)V");
  if (keystore_put == NULL || keystore_get == NULL || keystore_delete == NULL)
    return JNI_ERR;
  java_vm = vm;
  return JNI_VERSION_1_6;
}

static jbyteArray to_array(JNIEnv *env, const char *bytes, size_t length);

/* A keystore call's outcome, read once the OCaml runtime is held again. */
struct keystore_call {
  char *name;
  size_t name_length;
  char *entry; /* put: in; get: out, NULL when absent */
  size_t entry_length;
  char *failure; /* the Java exception's text, NULL on success */
};

static char *exception_text(JNIEnv *env) {
  jthrowable thrown = (*env)->ExceptionOccurred(env);
  (*env)->ExceptionClear(env);
  jclass throwable = (*env)->FindClass(env, "java/lang/Throwable");
  jmethodID to_string =
      (*env)->GetMethodID(env, throwable, "toString", "()Ljava/lang/String;");
  jstring text = (*env)->CallObjectMethod(env, thrown, to_string);
  char *copy = NULL;
  if (!(*env)->ExceptionCheck(env) && text != NULL) {
    const char *chars = (*env)->GetStringUTFChars(env, text, NULL);
    copy = strdup(chars);
    (*env)->ReleaseStringUTFChars(env, text, chars);
  }
  (*env)->ExceptionClear(env);
  return copy != NULL ? copy : strdup("the keystore failed");
}

static void run_keystore_call(char operation, struct keystore_call *call) {
  JNIEnv *env;
  int attached = 0;
  if ((*java_vm)->GetEnv(java_vm, (void **)&env, JNI_VERSION_1_6) ==
      JNI_EDETACHED) {
    if ((*java_vm)->AttachCurrentThread(java_vm, &env, NULL) != JNI_OK) {
      call->failure = strdup("the core thread cannot reach the JVM");
      return;
    }
    attached = 1;
  }
  if ((*env)->PushLocalFrame(env, 8) != 0) {
    (*env)->ExceptionClear(env);
    call->failure = strdup("the JVM has no memory for the keystore call");
    if (attached)
      (*java_vm)->DetachCurrentThread(java_vm);
    return;
  }
  jbyteArray name = to_array(env, call->name, call->name_length);
  jbyteArray entry = operation == 'p'
                         ? to_array(env, call->entry, call->entry_length)
                         : NULL;
  jbyteArray result = NULL;
  if (name == NULL || (operation == 'p' && entry == NULL)) {
    (*env)->ExceptionClear(env);
    call->failure = strdup("the JVM has no memory for the keystore call");
    (*env)->PopLocalFrame(env, NULL);
    if (attached)
      (*java_vm)->DetachCurrentThread(java_vm);
    return;
  }
  switch (operation) {
  case 'p':
    (*env)->CallStaticVoidMethod(env, keystore_class, keystore_put, name,
                                 entry);
    break;
  case 'g':
    result = (*env)->CallStaticObjectMethod(env, keystore_class, keystore_get,
                                            name);
    break;
  default:
    (*env)->CallStaticVoidMethod(env, keystore_class, keystore_delete, name);
  }
  if ((*env)->ExceptionCheck(env))
    call->failure = exception_text(env);
  else if (operation == 'g' && result != NULL) {
    call->entry_length = (*env)->GetArrayLength(env, result);
    call->entry = malloc(call->entry_length + 1);
    if (call->entry == NULL)
      abort();
    (*env)->GetByteArrayRegion(env, result, 0, call->entry_length,
                               (jbyte *)call->entry);
  }
  (*env)->PopLocalFrame(env, NULL);
  if (attached)
    (*java_vm)->DetachCurrentThread(java_vm);
}

static char *copy_value(value _bytes, size_t *length) {
  *length = caml_string_length(_bytes);
  char *copy = malloc(*length + 1);
  if (copy == NULL)
    abort();
  memcpy(copy, String_val(_bytes), *length);
  return copy;
}

/* The runtime is released while the JVM runs: a keystore operation can take
   tens of milliseconds, and the app's threads call into the core meanwhile. */
static void keystore_call(char operation, value _name, value _entry,
                          struct keystore_call *call) {
  call->name = copy_value(_name, &call->name_length);
  call->entry = operation == 'p' ? copy_value(_entry, &call->entry_length) : NULL;
  call->failure = NULL;
  caml_release_runtime_system();
  run_keystore_call(operation, call);
  caml_acquire_runtime_system();
  free(call->name);
  if (call->failure != NULL) {
    free(call->entry);
    value _failure = caml_copy_string(call->failure);
    free(call->failure);
    caml_raise_with_arg(*caml_named_value("tsync_keystore_failure"), _failure);
  }
}

CAMLprim value tsync_keystore_put(value _name, value _entry) {
  CAMLparam2(_name, _entry);
  struct keystore_call call;
  keystore_call('p', _name, _entry, &call);
  free(call.entry);
  CAMLreturn(Val_unit);
}

CAMLprim value tsync_keystore_get(value _name) {
  CAMLparam1(_name);
  CAMLlocal2(_entry, _found);
  struct keystore_call call;
  keystore_call('g', _name, Val_unit, &call);
  if (call.entry == NULL)
    CAMLreturn(Val_none);
  _entry = caml_alloc_initialized_string(call.entry_length, call.entry);
  free(call.entry);
  _found = caml_alloc_some(_entry);
  CAMLreturn(_found);
}

CAMLprim value tsync_keystore_delete(value _name) {
  CAMLparam1(_name);
  struct keystore_call call;
  keystore_call('d', _name, Val_unit, &call);
  CAMLreturn(Val_unit);
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
