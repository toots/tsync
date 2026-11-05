package org.feverdreamtv.tsync.core

/** The bridge of android.md §5, in platform strings. Every call blocks its calling thread. */
interface Core {
    /**
     * Checks the config, or [candidate] (a config's text) in its place.
     * @return null when accepted, else the core's sentence.
     */
    fun checkConfig(domain: String, candidate: String? = null): String?

    /** @return null when ready, else the core's sentence. */
    fun boot(domain: String): String?

    fun request(json: String): String

    /** Fetches and opens a setup link (setup-link §6.3), before any config exists; read by [SetupLink.parse]. */
    fun setupLink(link: String): String

    fun status(): String

    /** @return a handle > 0, or -errno. */
    fun open(ref: String): Long

    fun size(handle: Long): Long

    fun read(handle: Long, offset: Long, length: Int, dest: ByteArray): Int

    fun close(handle: Long): Int
}
