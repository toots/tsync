package org.feverdreamtv.tsync.core.backup

import org.feverdreamtv.tsync.core.Parameters

/** What processing does with one due record once its row is re-read (app §11.4 step 1). */
enum class Step { FORGET, WAIT, UPLOAD }

/** Why a pass holds back (app §11.7). */
enum class Hold { WIFI, BATTERY }

data class Device(val networkPresent: Boolean, val networkMetered: Boolean, val charging: Boolean, val batteryPercent: Int)

data class BackupSettings(val enabled: Boolean, val unmeteredOnly: Boolean, val whenBatteryOk: Boolean)

data class PassOutcome(val uploaded: Int, val failed: Int, val more: Boolean)

object Processing {
    /** PENDING, and FAILED whose next attempt is due (absent = due now), in capture order. */
    fun due(records: Collection<Record>, now: Long): List<Record> =
        records.filter { it.state == State.PENDING || (it.state == State.FAILED && (it.nextAttemptAt ?: 0) <= now) }
            .sortedWith(compareBy({ it.target }, { it.mediaId }))

    fun step(row: MediaRow?, now: Long): Step = when {
        row == null -> Step.FORGET
        row.pending || row.size <= 0 || now - row.modifiedSeconds * 1000 < Parameters.SETTLE_TIME_MS -> Step.WAIT
        else -> Step.UPLOAD
    }

    fun uploaded(record: Record, row: MediaRow, target: String, etag: String?, now: Long): Record = record.copy(
        target = target, size = row.size, modifiedSeconds = row.modifiedSeconds, state = State.DONE,
        lastError = null, updatedAt = now, etag = etag, nextAttemptAt = null,
    )

    /** FAILED is never terminal: it always carries its next attempt. */
    fun failed(record: Record, error: String, now: Long): Record {
        val attempts = record.attempts + 1
        return record.copy(
            state = State.FAILED, attempts = attempts, lastError = error, updatedAt = now,
            nextAttemptAt = now + Parameters.retryBackoffMs(attempts),
        )
    }

    /** A re-upload of a record that was DONE carries the content it replaces. */
    fun base(record: Record): String? = record.etag?.takeIf { it.isNotEmpty() }

    fun gate(settings: BackupSettings, device: Device): Hold? = when {
        settings.unmeteredOnly && (!device.networkPresent || device.networkMetered) -> Hold.WIFI
        settings.whenBatteryOk && !device.charging && device.batteryPercent < Parameters.BATTERY_FLOOR_PERCENT -> Hold.BATTERY
        else -> null
    }

    /** app §11.6: whether one more item fits the pass's budgets. */
    fun withinBudget(stagedBytes: Long, elapsedMs: Long, freeBytes: Long, itemSize: Long): Boolean =
        stagedBytes < Parameters.STAGED_BYTES_BUDGET &&
            elapsedMs < Parameters.PASS_TIME_BUDGET_MS &&
            freeBytes >= 2 * itemSize

    fun settled(records: Collection<Record>): Boolean = records.none { it.state == State.PENDING || it.state == State.FAILED }
}
