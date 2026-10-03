package org.feverdreamtv.tsync.core

/** app §13. */
object Parameters {
    const val OBSERVED_REFRESH_MS = 30_000L
    const val STATUS_POLL_MS = 2_000L
    const val MAX_TREE_DEPTH = 4096
    const val MAX_NAME_ATTEMPTS = 1000
    const val STAGING_ORPHAN_AGE_MS = 24 * 3_600_000L
    const val CHECK_SERVER_TIMEOUT_MS = 10_000
    const val SETTLE_TIME_MS = 10_000L
    const val DATE_ADDED_LOOKBACK_S = 24 * 3_600L
    const val FULL_DISCOVERY_INTERVAL_MS = 7 * 24 * 3_600_000L
    const val STAGED_BYTES_BUDGET = 512L * 1024 * 1024
    const val PASS_TIME_BUDGET_MS = 8 * 60_000L
    const val BATTERY_FLOOR_PERCENT = 15
    const val TRIGGER_DELAY_S = 10L
    const val TRIGGER_MAX_DELAY_S = 300L
    const val PERIODIC_INTERVAL_H = 6L
    const val MIN_SECRET_LENGTH = 32
    const val DEFAULT_MAX_CACHE = "2G"
    const val ROOT = "root"

    fun retryBackoffMs(attempts: Int): Long {
        val cap = 6 * 3_600_000L
        val doublings = (attempts - 1).coerceIn(0, 10)
        return minOf(15 * 60_000L shl doublings, cap)
    }
}
