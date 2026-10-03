package org.feverdreamtv.tsync.core.backup

/** app §11.2. A value another writer produced reads as FAILED. */
enum class State {
    PENDING, DONE, FAILED, BASELINE;

    companion object {
        fun of(text: String): State = entries.firstOrNull { it.name == text } ?: FAILED
    }
}

/** One media item's durable record (app §11.2). */
data class Record(
    val mediaId: Long,
    val volume: String,
    val target: String,
    val size: Long,
    val modifiedSeconds: Long,
    val state: State,
    val attempts: Int = 0,
    val lastError: String? = null,
    val updatedAt: Long,
    val etag: String? = null,
    val nextAttemptAt: Long? = null,
)

/** A row of the media store, as discovery and processing read it. */
data class MediaRow(
    val id: Long,
    val displayName: String,
    val size: Long,
    val modifiedSeconds: Long,
    val dateAddedSeconds: Long,
    val dateTakenMillis: Long?,
    /** Absent on platforms without modification generations. */
    val generation: Long?,
    val pending: Boolean = false,
) {
    val captureMillis: Long get() = dateTakenMillis?.takeIf { it > 0 } ?: (dateAddedSeconds * 1000)
}

/** Where the next discovery query starts; never whether an item is uploaded (app §11.1). */
data class Mark(
    val generation: Long = 0,
    val dateAdded: Long = 0,
    val version: String? = null,
    val fullDiscoveryAt: Long? = null,
) {
    val isZero: Boolean get() = generation == 0L && dateAdded == 0L

    fun covers(row: MediaRow): Boolean =
        if (row.generation != null) row.generation <= generation else row.dateAddedSeconds <= dateAdded
}

sealed interface RecordChange {
    /** Inserts the record, or replaces the one with its media id. */
    data class Put(val record: Record) : RecordChange
    data class Rekey(val from: Long, val to: Long) : RecordChange
    data class Delete(val mediaId: Long) : RecordChange
}
