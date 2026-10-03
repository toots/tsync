package org.feverdreamtv.tsync.core

/** app §9: the process-wide count of open work the platform must not freeze. */
class KeepAliveCounter {
    enum class Work { OPEN_FILE, SAVE }

    data class Held(val openFiles: Int, val saves: Int) {
        val total: Int get() = openFiles + saves
    }

    private val counts = IntArray(Work.entries.size)

    /** @return true exactly when the count went 0 → 1. */
    @Synchronized
    fun retain(work: Work): Boolean {
        counts[work.ordinal]++
        return counts.sum() == 1
    }

    /** @return true exactly when the count went 1 → 0. */
    @Synchronized
    fun release(work: Work): Boolean {
        if (counts[work.ordinal] == 0) return false
        counts[work.ordinal]--
        return counts.sum() == 0
    }

    @Synchronized
    fun held(): Held = Held(counts[Work.OPEN_FILE.ordinal], counts[Work.SAVE.ordinal])
}
