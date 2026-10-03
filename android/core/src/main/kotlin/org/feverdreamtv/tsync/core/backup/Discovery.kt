package org.feverdreamtv.tsync.core.backup

import org.feverdreamtv.tsync.core.Naming
import org.feverdreamtv.tsync.core.Parameters
import java.time.ZoneId

/** How one volume's discovery pass starts (app §11.3 steps 1 and 4). */
data class DiscoveryStart(val mark: Mark, val rebuilt: Boolean, val full: Boolean) {
    companion object {
        fun of(mark: Mark, volumeVersion: String, currentGeneration: Long?, now: Long): DiscoveryStart {
            val versionChanged = mark.version != null && mark.version != volumeVersion
            val generationFell = currentGeneration != null && currentGeneration < mark.generation
            val rebuilt = versionChanged || generationFell
            val start = if (rebuilt) Mark() else mark
            val fullDue = mark.fullDiscoveryAt == null || now - mark.fullDiscoveryAt > Parameters.FULL_DISCOVERY_INTERVAL_MS
            return DiscoveryStart(start.copy(version = volumeVersion, fullDiscoveryAt = mark.fullDiscoveryAt), rebuilt, rebuilt || fullDue)
        }
    }
}

/**
 * Turns the rows of one volume's query into record changes and the advanced mark (app §11.3
 * step 3). Deterministic: the same records and rows give the same changes.
 *
 * @param baseline a "from now on" pass: every new row is recorded as existing before backup
 * @param rebuilt the media store was rebuilt: ids may now name other items, so a record is
 *   matched to a row by target and size before its id is believed
 */
class DiscoveryPlanner(
    private val volume: String,
    records: Collection<Record>,
    private val start: DiscoveryStart,
    private val zone: ZoneId,
    private val now: Long,
    private val baseline: Boolean = false,
) {
    private val byId = records.associateByTo(sortedMapOf()) { it.mediaId }
    private val taken = records.mapTo(hashSetOf()) { it.target }
    private val oldestUpdate = records.minOfOrNull { it.updatedAt }
    private val matched = hashSetOf<Long>()
    private val changes = mutableListOf<RecordChange>()
    private var generation = start.mark.generation
    private var dateAdded = start.mark.dateAdded

    fun changes(): List<RecordChange> = changes

    /** The mark after the rows seen, stamped with a completed full discovery's time. */
    fun mark(): Mark = start.mark.copy(
        generation = generation,
        dateAdded = dateAdded,
        fullDiscoveryAt = if (start.full) now else start.mark.fullDiscoveryAt,
    )

    fun see(row: MediaRow) {
        row.generation?.let { generation = maxOf(generation, it) }
        dateAdded = maxOf(dateAdded, row.dateAddedSeconds)
        val target = Naming.cameraTarget(row.captureMillis, zone, row.displayName)
        val known = byId[row.id]
        val believed = known != null && (!start.rebuilt || Naming.unnumbered(known.target) == target)
        if (believed) refresh(known, row) else adopt(row, target, known)
        matched += row.id
    }

    private fun refresh(record: Record, row: MediaRow) {
        val unchanged = record.size == row.size && record.modifiedSeconds == row.modifiedSeconds
        if (unchanged || record.state == State.BASELINE) return
        val seen = record.copy(size = row.size, modifiedSeconds = row.modifiedSeconds, updatedAt = now)
        // An empty etag marks a re-upload whose base is unknown; only a first upload has none.
        val again = seen.copy(state = State.PENDING, attempts = 0, lastError = null, nextAttemptAt = null, etag = record.etag ?: "")
        put(if (record.state == State.DONE) again else seen)
    }

    private fun adopt(row: MediaRow, target: String, occupant: Record?) {
        val twin = renumbered(row, target)
        occupant?.let(::park)
        if (twin != null) rekey(twin, row.id) else put(fresh(row, target))
    }

    /** A record of the same capture and size under an id no row of this pass holds. */
    private fun renumbered(row: MediaRow, target: String): Record? = byId.values.firstOrNull {
        it.mediaId != row.id && it.mediaId !in matched && it.size == row.size &&
            (start.rebuilt || it.state == State.DONE) && Naming.unnumbered(it.target) == target
    }

    /** Moves a record whose id now names another item out of the way; its own row re-keys it. */
    private fun park(record: Record) {
        rekey(record, minOf(byId.firstKey(), 0) - 1)
    }

    private fun rekey(record: Record, to: Long) {
        byId.remove(record.mediaId)
        byId[to] = record.copy(mediaId = to)
        changes += RecordChange.Rekey(record.mediaId, to)
    }

    private fun put(record: Record) {
        byId[record.mediaId] = record
        taken += record.target
        changes += RecordChange.Put(record)
    }

    private fun fresh(row: MediaRow, target: String): Record = Record(
        mediaId = row.id,
        volume = volume,
        target = Naming.candidates(target).first { it !in taken },
        size = row.size,
        modifiedSeconds = row.modifiedSeconds,
        state = if (baseline || predatesBackup(row)) State.BASELINE else State.PENDING,
        updatedAt = now,
    )

    /** app §11.2: a row behind the mark without a record, which only another writer leaves. */
    private fun predatesBackup(row: MediaRow): Boolean {
        if (!start.mark.covers(row)) return false
        if (oldestUpdate == null) return !start.mark.isZero
        return row.dateAddedSeconds * 1000 <= oldestUpdate - Parameters.DATE_ADDED_LOOKBACK_S * 1000
    }
}
