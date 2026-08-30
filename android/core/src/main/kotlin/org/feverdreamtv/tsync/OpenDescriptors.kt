package org.feverdreamtv.tsync

/**
 * How many file descriptors the app is currently serving, and the two moments
 * that matter: the first one opening and the last one closing.
 *
 * A proxy descriptor's reads are answered in this process, so the process has
 * to stay out of the cached state for as long as one is open — Android freezes
 * a cached process, and a frozen one answers no reads at all. What holds it out
 * is a foreground service, and what says whether that service should be running
 * is this count.
 *
 * Pure by design: whether the service should be up is decidable without a
 * device, and the answer being wrong either way is expensive — a service that
 * stops early freezes playback, one that never stops holds the process and its
 * notification for good.
 */
object OpenDescriptors {

    private var open = 0

    /** Descriptors currently being served. */
    @get:Synchronized
    val count: Int
        get() = open

    /**
     * Take one. True when this is the one that crossed from none to some, which
     * is when the service has to start.
     */
    @Synchronized
    fun retain(): Boolean {
        open += 1
        return open == 1
    }

    /**
     * Give one back. True when this is the one that crossed from some to none,
     * which is when the service may stop.
     *
     * A release with nothing outstanding is ignored rather than driving the
     * count negative: an open that fails part way gives back what it took, and
     * a count that went below zero would need two more opens before the service
     * came back.
     */
    @Synchronized
    fun release(): Boolean {
        if (open == 0) return false
        open -= 1
        return open == 0
    }

    /** For tests: the process starts with nothing open, and each one wants to
     *  say so for itself. */
    @Synchronized
    fun reset() {
        open = 0
    }
}
