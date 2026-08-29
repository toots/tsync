/* The Java side of the bridge, and nothing else: every rule about threads, the
   runtime lock and the domain lives in tsync_bridge.c, which a host test can
   reach without a JVM. What is left here is marshalling. */

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <jni.h>
#include <stdlib.h>

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

JNIEXPORT jstring JNICALL Java_org_feverdreamtv_tsync_Native_nativeInit(
    JNIEnv *env, jclass cls, jstring _home, jstring _certificates,
    jstring _domain) {
    (void)cls;
    const char *home = (*env)->GetStringUTFChars(env, _home, NULL);
    const char *certificates =
        (*env)->GetStringUTFChars(env, _certificates, NULL);
    const char *domain =
        _domain ? (*env)->GetStringUTFChars(env, _domain, NULL) : "";

    if (!runtime_started) {
        /* Before caml_startup, not after: module initialisers derive every path
           from HOME as they run, and Sys.getenv raising there is an exit(2)
           printed to a stderr nobody reads. SSL_CERT_FILE for the same reason
           -- conduit builds its authenticator whether or not TLS is used. */
        setenv("HOME", home, 1);
        setenv("SSL_CERT_FILE", certificates, 1);
        char program[] = "tsync";
        char *argv[] = {program, NULL};
        caml_startup(argv);
        /* caml_startup leaves this thread holding the lock as the runtime's
           own, so it is marked rather than registered. */
        tsync_bridge_init();
        runtime_started = 1;
    } else {
        tsync_enter_ocaml();
    }

    jstring failure = NULL;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(boot, "tsync_jni_boot");
        answer = caml_callback(*boot, caml_copy_string(domain));
        if (String_val(answer)[0])
            failure = (*env)->NewStringUTF(env, String_val(answer));
        CAMLdrop;
    }
    tsync_leave_ocaml();

    (*env)->ReleaseStringUTFChars(env, _home, home);
    (*env)->ReleaseStringUTFChars(env, _certificates, certificates);
    if (_domain) (*env)->ReleaseStringUTFChars(env, _domain, domain);
    return failure;
}

JNIEXPORT jint JNICALL Java_org_feverdreamtv_tsync_Native_nativeOpen(
    JNIEnv *env, jclass cls, jstring _reference) {
    (void)cls;
    const char *reference = (*env)->GetStringUTFChars(env, _reference, NULL);
    tsync_enter_ocaml();
    jint handle;
    {
        CAMLparam0();
        CAMLlocal1(answer);
        TSYNC_ENTRY(open_entry, "tsync_jni_open");
        answer = caml_callback(*open_entry, caml_copy_string(reference));
        handle = (jint)Long_val(answer);
        CAMLdrop;
    }
    tsync_leave_ocaml();
    (*env)->ReleaseStringUTFChars(env, _reference, reference);
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
