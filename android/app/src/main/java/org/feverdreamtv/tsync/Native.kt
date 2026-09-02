package org.feverdreamtv.tsync

import android.content.Context

/**
 * The domain, linked in rather than exec'd.
 *
 * One OCaml runtime and one Lwt loop for the life of the process: every
 * request, and every read of an open file, is answered on that loop, so the
 * chunk cache, the upload queue and the locks that order changes to a domain
 * all live in one place. Calls arrive on whatever thread the platform hands
 * us; the C bridge registers each one with the runtime and blocks only its own
 * caller.
 *
 * Not a daemon: nothing survives the process, and everything a kill leaves
 * behind is replayed from the write-ahead log by the next [ensure].
 *
 * Text crosses as UTF-8 bytes rather than as JNI strings, which cannot carry
 * every name a file may have.
 */
object Native {
    init {
        System.loadLibrary("tsyncjni")
    }

    @Volatile
    var started = false
        private set

    /**
     * Idempotent, and the first caller waits for the domain to be serving.
     *
     * Never from the main thread: booting reads the manifest tree. Every caller
     * is a binder or worker thread already.
     */
    @Synchronized
    fun ensure(context: Context) {
        if (started) return
        val (home, certificates, domain) = environment(context)
        val failure = nativeInit(home, certificates, domain)
        if (failure != null) {
            throw IllegalStateException("tsync could not open the domain: ${String(failure)}")
        }
        started = true
    }

    /** Whether the config on disk is one the domain could start from, without
     *  starting it: null when it is, else what is wrong with it. */
    @Synchronized
    fun checkConfig(context: Context): String? {
        val (home, certificates, domain) = environment(context)
        return nativeCheckConfig(home, certificates, domain)?.let { String(it) }
    }

    /** Where the runtime finds everything, and which domain it serves: "" for
     *  the one the config names alone. */
    private fun environment(context: Context) = Triple(
        context.filesDir.absolutePath,
        Tsync.caBundle(context).absolutePath,
        (Config.load(context)?.domain ?: "").toByteArray()
    )

    /** One JSON request in, one JSON reply out. A change returns once its
     *  upload has drained. */
    fun request(context: Context, request: String): String {
        ensure(context)
        return String(nativeRequest(request.toByteArray()))
    }

    /** `tsync status` for this domain, as text a person reads. */
    fun status(context: Context): String {
        ensure(context)
        return String(nativeStatus())
    }

    private external fun nativeCheckConfig(
        home: String,
        caBundle: String,
        domain: ByteArray
    ): ByteArray?

    /** Null on success, else what went wrong, for a message a person reads. */
    private external fun nativeInit(
        home: String,
        caBundle: String,
        domain: ByteArray
    ): ByteArray?

    private external fun nativeRequest(request: ByteArray): ByteArray

    private external fun nativeStatus(): ByteArray

    /** A handle, or a negative errno. */
    external fun nativeOpen(reference: ByteArray): Int

    external fun nativeSize(handle: Int): Long

    /** Bytes served, or a negative errno; short only at end of content. */
    external fun nativeRead(
        handle: Int,
        offset: Long,
        length: Int,
        destination: ByteArray
    ): Int

    external fun nativeClose(handle: Int): Int
}
