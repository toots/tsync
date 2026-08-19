package org.feverdreamtv.tsync.backup

/**
 * One row of the camera roll, free of Android types so the planner that reads
 * them can be exercised without a device.
 */
data class MediaRow(
    val mediaId: Long,
    val volume: String,
    val displayName: String,
    /** Capture time where MediaStore has one, else the time it was added. */
    val captureMillis: Long,
    val sizeBytes: Long,

    /** What the sweep's watermark is made of below API 30, so it has to be the
     *  column the query cuts on and not a neighbouring one. */
    val addedSeconds: Long,
    val modifiedSeconds: Long,
    /** Zero below API 30, where MediaStore has no generation to report. */
    val generation: Long,
    val isVideo: Boolean,
    /** The camera has inserted the row but not finished writing the bytes. */
    val isPending: Boolean
)

enum class UploadState { DONE, FAILED }

/**
 * What this device knows about one of its own photos.
 *
 * [relativePath] is frozen at first sight: the domain is not asked whether a
 * photo was uploaded, since it knows nothing about media ids and a photo the
 * owner later deleted from it would otherwise upload again forever.
 */
data class UploadRecord(
    val mediaId: Long,
    val relativePath: String,
    val sizeBytes: Long,
    val modifiedSeconds: Long,
    val state: UploadState
)

sealed interface BackupAction {
    data class Upload(val row: MediaRow, val relativePath: String) : BackupAction

    data class Skip(val row: MediaRow, val reason: SkipReason) : BackupAction
}

enum class SkipReason {
    /** Uploaded already, at this size and modification time. */
    ALREADY_DONE,

    /** The bytes are still being written. */
    STILL_PENDING,

    /** Changed too recently to be trusted as complete. */
    UNSETTLED,

    EMPTY
}
