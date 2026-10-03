package org.feverdreamtv.tsync.backup

import android.content.Context
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteConstraintException
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import org.feverdreamtv.tsync.core.backup.BackupSettings
import org.feverdreamtv.tsync.core.backup.Mark
import org.feverdreamtv.tsync.core.backup.Processing
import org.feverdreamtv.tsync.core.backup.Record
import org.feverdreamtv.tsync.core.backup.RecordChange
import org.feverdreamtv.tsync.core.backup.State
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The persistent formats of app §11.2, on the platform's SQLite. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class RecordDbTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private var db: RecordDb? = null

    private fun open(): RecordDb = RecordDb(context).also { db = it }

    @After
    fun close() {
        db?.close()
        context.deleteDatabase(RecordDb.NAME)
    }

    private fun schema(db: SQLiteDatabase): List<String> =
        db.rawQuery("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'android_%' ORDER BY name", null).use { cursor ->
            generateSequence { if (cursor.moveToNext()) cursor.getString(0).replace(Regex("\\s+"), " ") else null }.toList()
        }

    private fun dump(db: SQLiteDatabase, columns: String): List<String> =
        db.rawQuery("SELECT $columns FROM media ORDER BY media_id", null).use { cursor ->
            generateSequence { if (cursor.moveToNext()) (0 until cursor.columnCount).joinToString("|") { cursor.getString(it) ?: "NULL" } else null }.toList()
        }

    /** The database `main`'s app left: version 2, without the two last columns and kinds of key. */
    private fun versionTwo() {
        val old = SQLiteDatabase.openOrCreateDatabase(context.getDatabasePath(RecordDb.NAME).apply { parentFile!!.mkdirs() }, null)
        old.execSQL(
            """CREATE TABLE media (media_id INTEGER PRIMARY KEY, volume TEXT NOT NULL, relative_path TEXT NOT NULL,
               size_bytes INTEGER NOT NULL, modified_seconds INTEGER NOT NULL, state TEXT NOT NULL,
               attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, updated_at INTEGER NOT NULL)"""
        )
        old.execSQL("CREATE UNIQUE INDEX media_path ON media(relative_path)")
        old.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        old.execSQL("CREATE TABLE dirs (path TEXT PRIMARY KEY, ref TEXT NOT NULL)")
        old.execSQL("INSERT INTO media VALUES (1, 'external_primary', 'Camera Uploads/2026/a.jpg', 10, 100, 'DONE', 0, NULL, 1000)")
        old.execSQL("INSERT INTO media VALUES (2, 'external_primary', 'Camera Uploads/2026/b.jpg', 20, 200, 'FAILED', 3, 'boom', 2000)")
        old.execSQL("INSERT INTO media VALUES (3, 'external_primary', 'Camera Uploads/2026/c.jpg', 30, 300, 'QUARANTINED', 0, NULL, 3000)")
        old.execSQL("INSERT INTO meta VALUES ('watermark.external_primary.generation', '41')")
        old.execSQL("INSERT INTO meta VALUES ('watermark.external_primary.dateAdded', '1755347464')")
        old.execSQL("INSERT INTO dirs VALUES ('Camera Uploads/2026', 'd:9f3a')")
        old.version = 2
        old.close()
    }

    @Test
    fun aNewDatabaseHasTheSpecifiedSchema() {
        val fresh = open().readableDatabase
        assertEquals(3, fresh.version)
        assertEquals(
            listOf(
                "CREATE TABLE dirs (path TEXT PRIMARY KEY, ref TEXT NOT NULL)",
                "CREATE TABLE media ( media_id INTEGER PRIMARY KEY, volume TEXT NOT NULL, relative_path TEXT NOT NULL, " +
                    "size_bytes INTEGER NOT NULL, modified_seconds INTEGER NOT NULL, state TEXT NOT NULL, " +
                    "attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, updated_at INTEGER NOT NULL, etag TEXT, next_attempt_at INTEGER)",
                "CREATE UNIQUE INDEX media_path ON media(relative_path)",
                "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            ),
            schema(fresh),
        )
    }

    @Test
    fun aVersionTwoDatabaseIsTakenOverWithoutRewritingARow() {
        versionTwo()
        val columns = "media_id, volume, relative_path, size_bytes, modified_seconds, state, attempts, last_error, updated_at"
        val before = SQLiteDatabase.openDatabase(context.getDatabasePath(RecordDb.NAME).path, null, SQLiteDatabase.OPEN_READONLY).use { dump(it, columns) }
        assertEquals(3, before.size)
        val upgraded = open()
        assertEquals(3, upgraded.readableDatabase.version)
        assertEquals(before, dump(upgraded.readableDatabase, columns))
        val records = upgraded.records()
        assertEquals(listOf(State.DONE, State.FAILED, State.FAILED), records.map { it.state })
        assertTrue(records.all { it.etag == null && it.nextAttemptAt == null })
        // A record without its optional parts: due now, and a re-upload carries no base.
        assertEquals(listOf(2L, 3L), Processing.due(records, 0).map { it.mediaId })
        assertNull(Processing.base(records[0]))
        assertEquals("QUARANTINED", DatabaseUtils.stringForQuery(upgraded.readableDatabase, "SELECT state FROM media WHERE media_id = 3", null))
        assertEquals(Mark(41, 1755347464, version = null, fullDiscoveryAt = null), upgraded.mark("external_primary"))
        assertEquals("d:9f3a", upgraded.get("Camera Uploads/2026"))
    }

    @Test
    fun changesAndTheMarkMoveInOneTransaction() {
        val store = open()
        val record = Record(7, "external_primary", "Camera Uploads/2026/a.jpg", 10, 100, State.PENDING, updatedAt = 1)
        store.apply("external_primary", listOf(RecordChange.Put(record), RecordChange.Rekey(7, 9)), Mark(5, 6, "v1", 7))
        assertEquals(listOf(record.copy(mediaId = 9)), store.records())
        assertEquals(Mark(5, 6, "v1", 7), store.mark("external_primary"))
        assertEquals(Mark(), store.mark("other"))
        assertTrue(store.targetTaken("Camera Uploads/2026/a.jpg"))
        assertFalse(store.targetTaken("Camera Uploads/2026/b.jpg"))

        val clash = record.copy(mediaId = 10)
        assertThrows(SQLiteConstraintException::class.java) {
            store.apply("external_primary", listOf(RecordChange.Put(record.copy(mediaId = 11, target = "x")), RecordChange.Put(clash)), Mark(50, 60, "v2", 70))
        }
        assertEquals(listOf(9L), store.records().map { it.mediaId })
        assertEquals(Mark(5, 6, "v1", 7), store.mark("external_primary"))

        val failed = Processing.failed(record.copy(mediaId = 9), "boom", 1000)
        store.put(failed)
        assertEquals(listOf(failed), store.records())
        store.delete(9)
        assertEquals(emptyList<Record>(), store.records())
    }

    @Test
    fun theFolderCacheIsDisposable() {
        val store = open()
        store.put("Camera Uploads", "d:1")
        store.put("Camera Uploads", "d:2")
        assertEquals("d:2", store.get("Camera Uploads"))
        store.remove("Camera Uploads")
        assertNull(store.get("Camera Uploads"))
    }

    @Test
    fun settingsUseTheSpecifiedKeysAndDefaults() {
        val prefs = BackupPrefs(context)
        assertEquals(BackupSettings(enabled = false, unmeteredOnly = true, whenBatteryOk = true), prefs.settings)
        assertNull(prefs.lastOutcome)
        prefs.settings = BackupSettings(enabled = true, unmeteredOnly = false, whenBatteryOk = false)
        prefs.lastOutcome = "3 uploaded"
        val stored = context.getSharedPreferences("camera-backup", Context.MODE_PRIVATE).all
        assertEquals(mapOf("enabled" to true, "unmeteredOnly" to false, "whenBatteryOk" to false, "lastOutcome" to "3 uploaded"), stored)
    }
}
