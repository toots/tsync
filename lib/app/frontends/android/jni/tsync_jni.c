/* The Java side of the bridge, and nothing else: every rule about threads, the
   runtime lock and the domain lives in tsync_bridge.c, which a host test can
   reach without a JVM. What is left here is marshalling.

   Strings cross as byte arrays: a JNI jstring is modified UTF-8, which a name
   holding a character outside the basic plane neither arrives as nor may be
   handed back as -- NewStringUTF on such bytes is a JNI abort. */

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <jni.h>
#include <stdlib.h>
#include <string.h>

void tsync_bridge_init(void);
void tsync_enter_ocaml(void);
void tsync_leave_ocaml(void);

/* Serialised by the caller (Native.ensure is synchronized), which is also what
   makes the one-time startup below safe to check without a lock. */
static int runtime_started = 0;

/* caml_named_value hands back a pointer that stays valid, so each entry point
   is looked up once. */
#define TSYNC_ENTRY(var, name)                                                 \
    static const value *var = NULL;                                            \
    if (!var) var = caml_named_value(name);

/* Returns holding the runtime lock, starting the runtime the first time.
   Before caml_startup, not after: module initialisers derive every path from
   HOME as they run, and Sys.getenv raising there is an exit(2) printed to a
   stderr nobody reads. SSL_CERT_FILE for the same reason -- conduit builds its
   authenticator whether or not TLS is used. */
static void ensure_runtime(JNIEnv *env, jstring _home, jstring _certificates) {
    if (runtime_started) {
        tsync_enter_ocaml();
        return;
    }
    const char *home = (*env)->GetStringUTFChars(env, _home, NULL);
    const char *certificates =
        (*env)->GetStringUTFChars(env, _certificates, NULL);
    setenv("HOME", home, 1);
    setenv("SSL_CERT_FILE", certificates, 1);
    (*env)->ReleaseStringUTFChars(env, _home, home);
    (*env)->ReleaseStringUTFChars(env, _certificates, certificates);
    char program[] = "tsync";
    char *argv[] = {program, NULL};
    caml_startup(argv);
    /* caml_startup leaves this thread holding the lock as the runtime's own,
       so it is marked rather than registered. */
    tsync_bridge_init();
    runtime_started = 1;
}

/* Under the runtime lock: allocates. */
static value string_of_bytes(JNIEnv *env, jbyteArray bytes) {
    CAMLparam0();
    CAMLlocal1(result);
    jsize length = (*env)->GetArrayLength(env, bytes);
    result = caml_alloc_string(length);
    (*env)->GetByteArrayRegion(env, bytes, 0, length,
                               (jbyte *)Bytes_val(result));
    CAMLreturn(result);
}

/* Under the runtime lock, so [text] cannot move while the region is copied;
   SetByteArrayRegion allocates nothing on the JVM side. */
static jbyteArray bytes_of_string(JNIEnv *env, value text) {
    jsize length = (jsize)caml_string_length(text);
    jbyteArray bytes = (*env)->NewByteArray(env, length);
    if (bytes)
        (*env)->SetByteArrayRegion(env, bytes, 0, length,
                                   (const jbyte *)String_val(text));
    return bytes;
}

/* An empty answer is success; anything else is what went wrong. */
static jbyteArray failure_of(JNIEnv *env, value answer) {
    return caml_string_length(answer) ? bytes_of_string(env, answer) : NULL;
}

JNIEXPORT jbyteArray JNICALL Java_org_feverdreamtv_tsync_Native_nativeCheckConfig(
    JNIEnv *env, jclass cls, jstring _home, jstring _certificates,
    jbyteArray _domain) {
    (void)cls;
    ensure_runtime(env, _home, _certificates);
    jbyteArray failure;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(check, "tsync_jni_check_config");
        answer = caml_callback(*check, string_of_bytes(env, _domain));
        failure = failure_of(env, answer);
        CAMLdrop;
    }
    tsync_leave_ocaml();
    return failure;
}

JNIEXPORT jbyteArray JNICALL Java_org_feverdreamtv_tsync_Native_nativeInit(
    JNIEnv *env, jclass cls, jstring _home, jstring _certificates,
    jbyteArray _domain) {
    (void)cls;
    ensure_runtime(env, _home, _certificates);
    jbyteArray failure;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(boot, "tsync_jni_boot");
        answer = caml_callback(*boot, string_of_bytes(env, _domain));
        failure = failure_of(env, answer);
        CAMLdrop;
    }
    tsync_leave_ocaml();
    return failure;
}

JNIEXPORT jbyteArray JNICALL Java_org_feverdreamtv_tsync_Native_nativeRequest(
    JNIEnv *env, jclass cls, jbyteArray _request) {
    (void)cls;
    tsync_enter_ocaml();
    jbyteArray reply;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(request, "tsync_jni_request");
        answer = caml_callback(*request, string_of_bytes(env, _request));
        reply = bytes_of_string(env, answer);
        CAMLdrop;
    }
    tsync_leave_ocaml();
    return reply;
}

JNIEXPORT jbyteArray JNICALL Java_org_feverdreamtv_tsync_Native_nativeStatus(
    JNIEnv *env, jclass cls) {
    (void)cls;
    tsync_enter_ocaml();
    jbyteArray report;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(status, "tsync_jni_status");
        answer = caml_callback(*status, Val_unit);
        report = bytes_of_string(env, answer);
        CAMLdrop;
    }
    tsync_leave_ocaml();
    return report;
}

JNIEXPORT jint JNICALL Java_org_feverdreamtv_tsync_Native_nativeOpen(
    JNIEnv *env, jclass cls, jbyteArray _reference) {
    (void)cls;
    tsync_enter_ocaml();
    jint handle;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(open_entry, "tsync_jni_open");
        answer = caml_callback(*open_entry, string_of_bytes(env, _reference));
        handle = (jint)Long_val(answer);
        CAMLdrop;
    }
    tsync_leave_ocaml();
    return handle;
}

JNIEXPORT jlong JNICALL Java_org_feverdreamtv_tsync_Native_nativeSize(
    JNIEnv *env, jclass cls, jint handle) {
    (void)env;
    (void)cls;
    tsync_enter_ocaml();
    jlong size;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(size_entry, "tsync_jni_size");
        answer = caml_callback(*size_entry, Val_int(handle));
        size = (jlong)Int64_val(answer);
        CAMLdrop;
    }
    tsync_leave_ocaml();
    return size;
}

/* The bytes are copied out rather than read into a pinned array:
   GetPrimitiveArrayCritical forbids other JNI calls and must be brief, while
   this read can wait on a backend for as long as the network takes -- and a
   critical section held that long stalls the collector of the host VM. */
JNIEXPORT jint JNICALL Java_org_feverdreamtv_tsync_Native_nativeRead(
    JNIEnv *env, jclass cls, jint handle, jlong offset, jint length,
    jbyteArray destination) {
    (void)cls;
    tsync_enter_ocaml();
    jint served;
    {
        CAMLparam0();
        CAMLlocal2(buffer, answer);
        intnat dimension = length;
        buffer = caml_ba_alloc(
            CAML_BA_UINT8 | CAML_BA_C_LAYOUT | CAML_BA_MANAGED, 1, NULL,
            &dimension);
        TSYNC_ENTRY(read_entry, "tsync_jni_read");
        answer = caml_callback3(*read_entry, Val_int(handle),
                                caml_copy_int64(offset), buffer);
        served = (jint)Long_val(answer);
        /* Under the runtime lock, so the buffer cannot move or be collected;
           SetByteArrayRegion allocates nothing and cannot trigger a JVM
           collection of its own. */
        if (served > 0)
            (*env)->SetByteArrayRegion(env, destination, 0, served,
                                       (const jbyte *)Caml_ba_data_val(buffer));
        CAMLdrop;
    }
    tsync_leave_ocaml();
    return served;
}

JNIEXPORT jint JNICALL Java_org_feverdreamtv_tsync_Native_nativeClose(
    JNIEnv *env, jclass cls, jint handle) {
    (void)env;
    (void)cls;
    tsync_enter_ocaml();
    jint result;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(close_entry, "tsync_jni_close");
        answer = caml_callback(*close_entry, Val_int(handle));
        result = (jint)Long_val(answer);
        CAMLdrop;
    }
    tsync_leave_ocaml();
    return result;
}
