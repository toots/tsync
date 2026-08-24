package org.feverdreamtv.tsync.backup

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** How far a volume has been swept. */
data class Watermark(val generation: Long, val dateAddedSeconds: Long) {
    companion object {
        val BEGINNING = Watermark(0, 0)
    }
}

/**
 * What this device has done with its own camera roll.
 *
 * Hand-written rather than through Room, which would be the only reason this app
 * needs an annotation processor.
 */
class UploadRecords(context: Context) :
    SQLiteOpenHelper(context, NAME, null, VERSION) {

    companion object {
        private const val NAME = "camera-backup.db"
        private const val VERSION = 2
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE media (
              media_id INTEGER PRIMARY KEY,
              volume TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              size_bytes INTEGER NOT NULL,
              modified_seconds INTEGER NOT NULL,
              state TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              updated_at INTEGER NOT NULL
            )
            """.trimIndent()
        )
        // A rebuilt MediaProvider renumbers every id, so a fresh row claiming a
        // dead row's name replaces it rather than doubling the entry.
        db.execSQL("CREATE UNIQUE INDEX media_path ON media(relative_path)")
        db.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execSQL("CREATE TABLE dirs (path TEXT PRIMARY KEY, ref TEXT NOT NULL)")
    }

    /** Only the folder cache is dropped: what a sweep has uploaded is real
     *  state, and losing it would send every photo a second time. */
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS dirs")
        db.execSQL("CREATE TABLE dirs (path TEXT PRIMARY KEY, ref TEXT NOT NULL)")
    }

    // ── Records ──────────────────────────────────────────────────────────────

    fun all(): Map<Long, UploadRecord> {
        val records = mutableMapOf<Long, UploadRecord>()
        readableDatabase.query(
            "media",
            arrayOf("media_id", "relative_path", "size_bytes", "modified_seconds", "state"),
            null, null, null, null, null
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val record = UploadRecord(
                    mediaId = cursor.getLong(0),
                    relativePath = cursor.getString(1),
                    sizeBytes = cursor.getLong(2),
                    modifiedSeconds = cursor.getLong(3),
                    state = runCatching { UploadState.valueOf(cursor.getString(4)) }
                        .getOrDefault(UploadState.FAILED)
                )
                records[record.mediaId] = record
            }
        }
        return records
    }

    fun put(record: UploadRecord, volume: String, error: String? = null) {
        val values = ContentValues().apply {
            put("media_id", record.mediaId)
            put("volume", volume)
            put("relative_path", record.relativePath)
            put("size_bytes", record.sizeBytes)
            put("modified_seconds", record.modifiedSeconds)
            put("state", record.state.name)
            put("last_error", error)
            put("updated_at", System.currentTimeMillis())
        }
        writableDatabase.insertWithOnConflict(
            "media", null, values, SQLiteDatabase.CONFLICT_REPLACE
        )
    }

    /** The most recently recorded failure, which for a whole roll refused the
     *  same way is the reason for all of them. */
    fun lastError(): String? =
        readableDatabase.rawQuery(
            "SELECT last_error FROM media WHERE last_error IS NOT NULL " +
                "ORDER BY updated_at DESC LIMIT 1",
            null
        ).use { if (it.moveToFirst()) it.getString(0) else null }

    fun countInState(state: UploadState): Int =
        readableDatabase.rawQuery(
            "SELECT COUNT(*) FROM media WHERE state = ?", arrayOf(state.name)
        ).use { if (it.moveToFirst()) it.getInt(0) else 0 }

    // ── Watermarks ───────────────────────────────────────────────────────────

    fun watermark(volume: String): Watermark = Watermark(
        generation = meta("watermark.$volume.generation")?.toLongOrNull()
            ?: Watermark.BEGINNING.generation,
        dateAddedSeconds = meta("watermark.$volume.dateAdded")?.toLongOrNull()
            ?: Watermark.BEGINNING.dateAddedSeconds
    )

    fun setWatermark(volume: String, watermark: Watermark) {
        setMeta("watermark.$volume.generation", watermark.generation.toString())
        setMeta("watermark.$volume.dateAdded", watermark.dateAddedSeconds.toString())
    }

    private fun meta(key: String): String? =
        readableDatabase.query("meta", arrayOf("value"), "key = ?", arrayOf(key), null, null, null)
            .use { if (it.moveToFirst()) it.getString(0) else null }

    private fun setMeta(key: String, value: String) {
        writableDatabase.insertWithOnConflict(
            "meta", null,
            ContentValues().apply { put("key", key); put("value", value) },
            SQLiteDatabase.CONFLICT_REPLACE
        )
    }

    // ── Folders already created in the domain ────────────────────────────────

    /** Folder references already resolved, by the relative path each holds.
     *  A reference outlives a rename of the folder, so this stays true. */
    fun knownDirs(): MutableMap<String, String> {
        val refs = mutableMapOf<String, String>()
        readableDatabase.query("dirs", arrayOf("path", "ref"), null, null, null, null, null).use {
            while (it.moveToNext()) refs[it.getString(0)] = it.getString(1)
        }
        return refs
    }

    fun rememberDirs(refs: Map<String, String>) {
        val database = writableDatabase
        database.beginTransaction()
        try {
            refs.forEach { (path, ref) ->
                database.insertWithOnConflict(
                    "dirs", null,
                    ContentValues().apply {
                        put("path", path)
                        put("ref", ref)
                    },
                    SQLiteDatabase.CONFLICT_REPLACE
                )
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }
}
