package org.feverdreamtv.tsync.backup

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.MediaStore.Files.FileColumns
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.backup.Mark
import org.feverdreamtv.tsync.core.backup.MediaRow
import java.io.InputStream

enum class Access { FULL, SELECTED, DENIED }

/** The camera's photos and videos, as the media store shows them (app §11.3, §11.6). */
class MediaSource(private val context: Context) {
    private val hasGenerations = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
    private val hasVolumes = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    fun access(): Access = when {
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ->
            if (granted(Manifest.permission.READ_EXTERNAL_STORAGE)) Access.FULL else Access.DENIED
        granted(Manifest.permission.READ_MEDIA_IMAGES) && granted(Manifest.permission.READ_MEDIA_VIDEO) -> Access.FULL
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> Access.SELECTED
        else -> Access.DENIED
    }

    fun volumes(): List<String> =
        if (hasVolumes) MediaStore.getExternalVolumeNames(context).sorted() else listOf(MediaStore.VOLUME_EXTERNAL)

    fun version(volume: String): String =
        if (hasVolumes) MediaStore.getVersion(context, volume) else MediaStore.getVersion(context)

    fun generation(volume: String): Long? = if (hasGenerations) MediaStore.getGeneration(context, volume) else null

    private fun columns(): Array<String> = listOfNotNull(
        FileColumns._ID, FileColumns.DISPLAY_NAME, FileColumns.SIZE, FileColumns.DATE_MODIFIED, FileColumns.DATE_ADDED,
        DATE_TAKEN, FileColumns.MEDIA_TYPE,
        FileColumns.GENERATION_MODIFIED.takeIf { hasGenerations },
        FileColumns.IS_PENDING.takeIf { hasVolumes },
    ).toTypedArray()

    // DCIM at any depth: OEM cameras use their own subfolders.
    private val camera: String
        get() {
            val media = "${FileColumns.MEDIA_TYPE} IN (${FileColumns.MEDIA_TYPE_IMAGE}, ${FileColumns.MEDIA_TYPE_VIDEO})"
            val place = if (hasVolumes) "${FileColumns.RELATIVE_PATH} LIKE 'DCIM/%'" else "${FileColumns.DATA} LIKE '%/DCIM/%'"
            return "$media AND $place"
        }

    /** Rows newer than the mark, or every row when `mark` is null; ordered by id. */
    fun rows(volume: String, mark: Mark?): List<MediaRow> {
        val newer = when {
            mark == null -> ""
            hasGenerations -> " AND ${FileColumns.GENERATION_MODIFIED} > ${mark.generation}"
            // Date-added is not monotonic, so the query reaches back behind the mark.
            else -> " AND ${FileColumns.DATE_ADDED} > ${mark.dateAdded - Parameters.DATE_ADDED_LOOKBACK_S}"
        }
        return query(volume, camera + newer, null)
    }

    fun row(volume: String, id: Long): MediaRow? = query(volume, "${FileColumns._ID} = ?", arrayOf(id.toString())).firstOrNull()

    private fun query(volume: String, selection: String, arguments: Array<String>?): List<MediaRow> {
        val cursor = context.contentResolver.query(MediaStore.Files.getContentUri(volume), columns(), selection, arguments, FileColumns._ID)
            ?: throw IllegalStateException("the media store did not answer for $volume")
        return cursor.use { generateSequence { if (it.moveToNext()) row(it) else null }.toList() }
    }

    private fun row(cursor: Cursor): MediaRow {
        fun long(name: String) = cursor.getLong(cursor.getColumnIndexOrThrow(name))
        return MediaRow(
            id = long(FileColumns._ID),
            displayName = cursor.getString(cursor.getColumnIndexOrThrow(FileColumns.DISPLAY_NAME)).orEmpty(),
            size = long(FileColumns.SIZE),
            modifiedSeconds = long(FileColumns.DATE_MODIFIED),
            dateAddedSeconds = long(FileColumns.DATE_ADDED),
            dateTakenMillis = long(DATE_TAKEN).takeIf { it > 0 },
            generation = if (hasGenerations) long(FileColumns.GENERATION_MODIFIED) else null,
            pending = hasVolumes && long(FileColumns.IS_PENDING) != 0L,
        )
    }

    /** The original bytes, location metadata included where the user allowed it. */
    fun open(volume: String, row: MediaRow): InputStream {
        val item = ContentUris.withAppendedId(collection(volume, row.id), row.id)
        val original = if (hasVolumes && granted(Manifest.permission.ACCESS_MEDIA_LOCATION)) MediaStore.setRequireOriginal(item) else item
        return context.contentResolver.openInputStream(original) ?: throw java.io.IOException("the media store gave no stream for ${row.displayName}")
    }

    // Unredacted originals are only served through the image and video collections.
    private fun collection(volume: String, id: Long): Uri {
        val files = MediaStore.Files.getContentUri(volume)
        val type = context.contentResolver.query(files, arrayOf(FileColumns.MEDIA_TYPE), "${FileColumns._ID} = ?", arrayOf(id.toString()), null)
            ?.use { if (it.moveToFirst()) it.getInt(0) else null }
        return when (type) {
            FileColumns.MEDIA_TYPE_VIDEO -> if (hasVolumes) MediaStore.Video.Media.getContentUri(volume) else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            FileColumns.MEDIA_TYPE_IMAGE -> if (hasVolumes) MediaStore.Images.Media.getContentUri(volume) else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            else -> files
        }
    }

    private companion object {
        const val DATE_TAKEN = "datetaken"
    }
}
