package org.feverdreamtv.tsync.backup

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.MediaStore

/**
 * The camera roll, as rows the planner can read.
 *
 * Deliberately thin: MediaStore's selection and projection semantics cannot be
 * exercised off a device, so no decision is taken here.
 */
object MediaScan {

    /** Matches DCIM at any depth, which is where OEM camera apps put their own
     *  directories — BUCKET_DISPLAY_NAME = 'Camera' misses every one of them. */
    private const val CAMERA_PATH = "DCIM/%"
    private const val CAMERA_DATA = "%/DCIM/%"

    data class Collection(val uri: Uri, val isVideo: Boolean)

    fun collections(volume: String): List<Collection> = listOf(
        Collection(MediaStore.Images.Media.getContentUri(volume), isVideo = false),
        Collection(MediaStore.Video.Media.getContentUri(volume), isVideo = true)
    )

    fun volumes(context: Context): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.getExternalVolumeNames(context).toList()
        } else {
            listOf(MediaStore.VOLUME_EXTERNAL)
        }

    /** The generation MediaStore is at, or zero where it has none to report. */
    fun currentGeneration(context: Context, volume: String): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            MediaStore.getGeneration(context, volume)
        } else {
            0
        }

    fun contentUri(collection: Collection, mediaId: Long): Uri =
        ContentUris.withAppendedId(collection.uri, mediaId)

    /** The largest DATE_ADDED on [volume], in the units a watermark is cut on. */
    fun newestAdded(context: Context, volume: String): Long =
        collections(volume).maxOf { collection ->
            context.contentResolver.query(
                collection.uri,
                arrayOf(MediaStore.MediaColumns.DATE_ADDED),
                null, null,
                "${MediaStore.MediaColumns.DATE_ADDED} DESC LIMIT 1"
            )?.use { if (it.moveToFirst()) it.getLong(0) else 0L } ?: 0L
        }

    /**
     * Opens the bytes as the camera wrote them.
     *
     * ACCESS_MEDIA_LOCATION alone is not enough — without setRequireOriginal the
     * stream is a redacted copy with the GPS tags stripped out.
     */
    fun originalUri(uri: Uri): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching { MediaStore.setRequireOriginal(uri) }.getOrDefault(uri)
        } else {
            uri
        }

    private fun projection(): Array<String> = buildList {
        add(MediaStore.MediaColumns._ID)
        add(MediaStore.MediaColumns.DISPLAY_NAME)
        add(MediaStore.MediaColumns.SIZE)
        add(MediaStore.MediaColumns.DATE_ADDED)
        add(MediaStore.MediaColumns.DATE_MODIFIED)
        add(MediaStore.MediaColumns.DATE_TAKEN)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            add(MediaStore.MediaColumns.IS_PENDING)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            add(MediaStore.MediaColumns.GENERATION_MODIFIED)
        }
    }.toTypedArray()

    /**
     * Everything in [collection] newer than [watermark].
     *
     * On API 30 and up the cut is the generation, which is monotonic; below it
     * DATE_ADDED, which is not — a restore or a media rescan backfills older
     * values, so the caller overlaps the window and lets the record dedupe.
     */
    fun query(
        context: Context,
        volume: String,
        collection: Collection,
        watermark: Watermark,
        lookbackSeconds: Long
    ): List<MediaRow> {
        val onCamera = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?" to CAMERA_PATH
        } else {
            @Suppress("DEPRECATION")
            "${MediaStore.MediaColumns.DATA} LIKE ?" to CAMERA_DATA
        }
        val since = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            "${MediaStore.MediaColumns.GENERATION_MODIFIED} > ?" to watermark.generation
        } else {
            "${MediaStore.MediaColumns.DATE_ADDED} > ?" to
                (watermark.dateAddedSeconds - lookbackSeconds).coerceAtLeast(0)
        }

        val selection = "${onCamera.first} AND ${since.first}"
        val arguments = arrayOf(onCamera.second, since.second.toString())

        return context.contentResolver.query(
            collection.uri, projection(), selection, arguments,
            "${MediaStore.MediaColumns._ID} ASC"
        )?.use { cursor ->
            generateSequence { if (cursor.moveToNext()) cursor else null }
                .map { rowOf(it, volume, collection) }
                .toList()
        } ?: emptyList()
    }

    private fun rowOf(cursor: Cursor, volume: String, collection: Collection): MediaRow {
        val dateAdded = cursor.longOr(MediaStore.MediaColumns.DATE_ADDED)
        val dateTaken = cursor.longOr(MediaStore.MediaColumns.DATE_TAKEN)
        return MediaRow(
            mediaId = cursor.longOr(MediaStore.MediaColumns._ID),
            volume = volume,
            displayName = cursor.stringOr(MediaStore.MediaColumns.DISPLAY_NAME),
            // Video routinely carries no DATE_TAKEN at all.
            captureMillis = if (dateTaken > 0) dateTaken else dateAdded * 1000,
            sizeBytes = cursor.longOr(MediaStore.MediaColumns.SIZE),
            addedSeconds = dateAdded,
            modifiedSeconds = cursor.longOr(MediaStore.MediaColumns.DATE_MODIFIED),
            generation = cursor.longOr(MediaStore.MediaColumns.GENERATION_MODIFIED),
            isVideo = collection.isVideo,
            isPending = cursor.longOr(MediaStore.MediaColumns.IS_PENDING) != 0L
        )
    }

    private fun Cursor.longOr(column: String, fallback: Long = 0): Long {
        val index = getColumnIndex(column)
        return if (index < 0 || isNull(index)) fallback else getLong(index)
    }

    private fun Cursor.stringOr(column: String, fallback: String = ""): String {
        val index = getColumnIndex(column)
        return if (index < 0 || isNull(index)) fallback else getString(index) ?: fallback
    }
}
