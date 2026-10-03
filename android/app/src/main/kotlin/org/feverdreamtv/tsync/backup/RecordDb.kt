package org.feverdreamtv.tsync.backup

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.feverdreamtv.tsync.core.FolderCache
import org.feverdreamtv.tsync.core.backup.Mark
import org.feverdreamtv.tsync.core.backup.Record
import org.feverdreamtv.tsync.core.backup.RecordChange
import org.feverdreamtv.tsync.core.backup.State

/** Camera-backup records, discovery marks and the folder cache (app §11.2), schema version 3. */
class RecordDb(context: Context) : SQLiteOpenHelper(context, NAME, null, VERSION), FolderCache {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE media (
                 media_id INTEGER PRIMARY KEY,
                 volume TEXT NOT NULL,
                 relative_path TEXT NOT NULL,
                 size_bytes INTEGER NOT NULL,
                 modified_seconds INTEGER NOT NULL,
                 state TEXT NOT NULL,
                 attempts INTEGER NOT NULL DEFAULT 0,
                 last_error TEXT,
                 updated_at INTEGER NOT NULL,
                 etag TEXT,
                 next_attempt_at INTEGER)"""
        )
        db.execSQL("CREATE UNIQUE INDEX media_path ON media(relative_path)")
        db.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        db.execSQL("CREATE TABLE dirs (path TEXT PRIMARY KEY, ref TEXT NOT NULL)")
    }

    // Version 2 lacks the two last columns; adding them rewrites no row, and a row without them
    // reads as the spec says a record without its optional parts reads.
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        val columns = db.rawQuery("PRAGMA table_info(media)", null).use { cursor ->
            generateSequence { if (cursor.moveToNext()) cursor.getString(1) else null }.toSet()
        }
        if ("etag" !in columns) db.execSQL("ALTER TABLE media ADD COLUMN etag TEXT")
        if ("next_attempt_at" !in columns) db.execSQL("ALTER TABLE media ADD COLUMN next_attempt_at INTEGER")
    }

    fun records(): List<Record> = readableDatabase.rawQuery("SELECT * FROM media ORDER BY media_id", null).use { cursor ->
        generateSequence { if (cursor.moveToNext()) record(cursor) else null }.toList()
    }

    private fun record(cursor: Cursor): Record {
        fun index(name: String) = cursor.getColumnIndexOrThrow(name)
        fun optionalLong(name: String) = index(name).let { if (cursor.isNull(it)) null else cursor.getLong(it) }
        return Record(
            mediaId = cursor.getLong(index("media_id")),
            volume = cursor.getString(index("volume")),
            target = cursor.getString(index("relative_path")),
            size = cursor.getLong(index("size_bytes")),
            modifiedSeconds = cursor.getLong(index("modified_seconds")),
            state = State.of(cursor.getString(index("state"))),
            attempts = cursor.getInt(index("attempts")),
            lastError = cursor.getString(index("last_error")),
            updatedAt = cursor.getLong(index("updated_at")),
            etag = cursor.getString(index("etag")),
            nextAttemptAt = optionalLong("next_attempt_at"),
        )
    }

    fun targetTaken(target: String): Boolean =
        readableDatabase.rawQuery("SELECT 1 FROM media WHERE relative_path = ?", arrayOf(target)).use { it.moveToFirst() }

    fun put(record: Record) = change(writableDatabase, RecordChange.Put(record))

    fun delete(mediaId: Long) = change(writableDatabase, RecordChange.Delete(mediaId))

    /** One transaction for a volume's discovered rows and its mark's advance (app §11.3 step 3). */
    fun apply(volume: String, changes: List<RecordChange>, mark: Mark) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            changes.forEach { change(db, it) }
            setMark(db, volume, mark)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun change(db: SQLiteDatabase, change: RecordChange) {
        when (change) {
            // Never "insert or replace": a clash on the unique target must fail, not drop the other record.
            is RecordChange.Put -> {
                val values = values(change.record)
                val updated = db.update("media", values, "media_id = ?", arrayOf(change.record.mediaId.toString()))
                if (updated == 0) db.insertOrThrow("media", null, values)
            }
            is RecordChange.Rekey -> db.execSQL("UPDATE media SET media_id = ? WHERE media_id = ?", arrayOf(change.to, change.from))
            is RecordChange.Delete -> db.delete("media", "media_id = ?", arrayOf(change.mediaId.toString()))
        }
    }

    private fun values(record: Record) = ContentValues().apply {
        put("media_id", record.mediaId)
        put("volume", record.volume)
        put("relative_path", record.target)
        put("size_bytes", record.size)
        put("modified_seconds", record.modifiedSeconds)
        put("state", record.state.name)
        put("attempts", record.attempts)
        put("last_error", record.lastError)
        put("updated_at", record.updatedAt)
        put("etag", record.etag)
        put("next_attempt_at", record.nextAttemptAt)
    }

    private fun meta(key: String): String? =
        readableDatabase.rawQuery("SELECT value FROM meta WHERE key = ?", arrayOf(key)).use { if (it.moveToFirst()) it.getString(0) else null }

    fun mark(volume: String) = Mark(
        generation = meta("watermark.$volume.generation")?.toLongOrNull() ?: 0,
        dateAdded = meta("watermark.$volume.dateAdded")?.toLongOrNull() ?: 0,
        version = meta("volume.$volume.version"),
        fullDiscoveryAt = meta("fullDiscovery.$volume")?.toLongOrNull(),
    )

    private fun setMark(db: SQLiteDatabase, volume: String, mark: Mark) {
        val entries = listOfNotNull(
            "watermark.$volume.generation" to mark.generation.toString(),
            "watermark.$volume.dateAdded" to mark.dateAdded.toString(),
            mark.version?.let { "volume.$volume.version" to it },
            mark.fullDiscoveryAt?.let { "fullDiscovery.$volume" to it.toString() },
        )
        for ((key, value) in entries) db.execSQL("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arrayOf(key, value))
    }

    override fun get(path: String): String? =
        readableDatabase.rawQuery("SELECT ref FROM dirs WHERE path = ?", arrayOf(path)).use { if (it.moveToFirst()) it.getString(0) else null }

    override fun put(path: String, ref: String) =
        writableDatabase.execSQL("INSERT OR REPLACE INTO dirs (path, ref) VALUES (?, ?)", arrayOf(path, ref))

    override fun remove(path: String) = writableDatabase.execSQL("DELETE FROM dirs WHERE path = ?", arrayOf(path))

    companion object {
        const val NAME = "camera-backup.db"
        const val VERSION = 3

        @Volatile
        private var instance: RecordDb? = null

        fun get(context: Context): RecordDb = instance ?: synchronized(this) {
            instance ?: RecordDb(context.applicationContext).also { instance = it }
        }
    }
}
