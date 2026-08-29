package org.feverdreamtv.tsync

import android.content.Context

/**
 * The domain, linked in rather than exec'd.
 *
 * One OCaml runtime and one Lwt loop for the life of the process, so a read is
 * served from a chunk cache that outlives the open file and the read-ahead in
 * lib/domain/checkout/content/data.ml has somewhere to run. Calls arrive on
 * whatever thread the platform hands us; the C bridge registers each one with
 * the runtime and blocks only its own caller.
 *
 * Not a daemon: nothing survives the process, and everything a kill leaves
 * behind is replayed from the write-ahead log by the next [ensure].
 */
object Native {
    init {
        System.loadLibrary("tsyncjni")
    }

    @Volatile
    private var started = false

    /**
     * Idempotent, and the first caller waits for the domain to be serving.
     *
     * Never from the main thread: booting reads the manifest tree. Every caller
     * is a binder or worker thread already.
     */
    @Synchronized
    fun ensure(context: Context) {
        if (started) return
        val failure = nativeInit(
            context.filesDir.absolutePath,
            Tsync.caBundle(context).absolutePath,
            Config.load(context)?.domain
        )
        check(failure == null) { "tsync could not open the domain: $failure" }
        started = true
    }

    /** Null on success, else what went wrong, for a message a person reads. */
    private external fun nativeInit(
        home: String,
        caBundle: String,
        domain: String?
    ): String?

    /** A handle, or a negative errno. */
    external fun nativeOpen(reference: String): Int

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
