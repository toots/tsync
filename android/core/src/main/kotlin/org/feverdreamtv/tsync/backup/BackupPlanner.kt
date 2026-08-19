package org.feverdreamtv.tsync.backup

import java.time.ZoneId

/**
 * Decides what a sweep should upload, given rows from the camera roll and what
 * this device already recorded about them.
 *
 * Pure by design: everything that can be wrong about a backup — uploading twice,
 * skipping a photo, taking a half-written video for a whole one — is decided
 * here, where it can be tested without a device.
 */
object BackupPlanner {

    /** A capture is trusted once it has been still this long. */
    const val SETTLE_MILLIS = 10_000L

    /** Bounds the search for a free name; a second holding this many captures
     *  is a camera roll problem, not a naming one. */
    private const val MAX_SEQUENCE = 1_000

    /**
     * How far a sweep may move a volume's watermark once it is finished with
     * [row].
     *
     * DATE_ADDED and nothing else: that is the column the query cuts on
     * (MediaScan.query), and DATE_MODIFIED — the neighbouring, usually larger
     * one — would carry the mark past captures that were never looked at.
     */
    fun advanceWatermark(previous: Long, row: MediaRow): Long =
        maxOf(previous, row.addedSeconds)

    fun plan(
        rows: List<MediaRow>,
        recorded: Map<Long, UploadRecord>,
        nowMillis: Long,
        zone: ZoneId,
        settleMillis: Long = SETTLE_MILLIS
    ): List<BackupAction> {
        val taken = recorded.values.mapTo(mutableSetOf()) { it.relativePath }
        val uploaded = recorded.values
            .filter { it.state == UploadState.DONE }
            .mapTo(mutableSetOf()) { it.relativePath to it.sizeBytes }

        return rows.sortedBy { it.mediaId }.map { row ->
            classify(row, recorded, taken, uploaded, nowMillis, zone, settleMillis)
        }
    }

    private fun classify(
        row: MediaRow,
        recorded: Map<Long, UploadRecord>,
        taken: MutableSet<String>,
        uploaded: Set<Pair<String, Long>>,
        nowMillis: Long,
        zone: ZoneId,
        settleMillis: Long
    ): BackupAction {
        if (row.isPending) return BackupAction.Skip(row, SkipReason.STILL_PENDING)
        if (row.sizeBytes <= 0) return BackupAction.Skip(row, SkipReason.EMPTY)
        if (nowMillis - row.modifiedSeconds * 1000 < settleMillis) {
            return BackupAction.Skip(row, SkipReason.UNSETTLED)
        }

        val record = recorded[row.mediaId]
        if (record != null) {
            val unchanged = record.sizeBytes == row.sizeBytes &&
                record.modifiedSeconds == row.modifiedSeconds
            return if (record.state == UploadState.DONE && unchanged) {
                BackupAction.Skip(row, SkipReason.ALREADY_DONE)
            } else {
                BackupAction.Upload(row, record.relativePath)
            }
        }

        return claimName(row, taken, uploaded, zone)
    }

    /**
     * Walks the sequence suffixes until a name is either recognisably one this
     * device already uploaded, or free.
     *
     * Checking both in one walk is what survives a MediaProvider rebuild, which
     * renumbers every id and would otherwise re-upload the whole roll: the old
     * records still hold the names, so a fresh row skipping straight past them
     * to a free suffix would never meet its own.
     */
    private fun claimName(
        row: MediaRow,
        taken: MutableSet<String>,
        uploaded: Set<Pair<String, Long>>,
        zone: ZoneId
    ): BackupAction {
        for (sequence in 0 until MAX_SEQUENCE) {
            val candidate =
                PhotoNaming.relativePath(row.captureMillis, row.displayName, zone, sequence)
            if (candidate to row.sizeBytes in uploaded) {
                return BackupAction.Skip(row, SkipReason.ALREADY_DONE)
            }
            if (taken.add(candidate)) return BackupAction.Upload(row, candidate)
        }
        error("no free name for ${row.displayName} after $MAX_SEQUENCE tries")
    }
}
