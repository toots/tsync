package org.feverdreamtv.tsync.backup

import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class UploadRecordsTest {

    private lateinit var records: UploadRecords

    @Before
    fun open() {
        records = UploadRecords(ApplicationProvider.getApplicationContext())
    }

    @After
    fun close() {
        records.close()
    }

    private fun record(
        id: Long,
        path: String = "Camera Uploads/2026/shot-$id.jpg",
        size: Long = 100,
        state: UploadState = UploadState.DONE
    ) = UploadRecord(id, path, size, 1_700_000_000, state)

    @Test
    fun `a stored record reads back`() {
        records.put(record(1), "external_primary")
        val stored = records.all().getValue(1)
        assertEquals("Camera Uploads/2026/shot-1.jpg", stored.relativePath)
        assertEquals(100, stored.sizeBytes)
        assertEquals(UploadState.DONE, stored.state)
    }

    @Test
    fun `storing the same id twice keeps one row`() {
        records.put(record(1, state = UploadState.FAILED), "external_primary")
        records.put(record(1, state = UploadState.DONE), "external_primary")
        assertEquals(1, records.all().size)
        assertEquals(UploadState.DONE, records.all().getValue(1).state)
    }

    /** A rebuilt MediaProvider renumbers ids, so a new id claiming a dead one's
     *  name has to replace it rather than leave the name recorded twice. */
    @Test
    fun `a new id claiming an existing name replaces the old row`() {
        records.put(record(1, path = "Camera Uploads/2026/a.jpg"), "external_primary")
        records.put(record(9001, path = "Camera Uploads/2026/a.jpg"), "external_primary")

        val all = records.all()
        assertEquals(1, all.size)
        assertNull(all[1])
        assertEquals("Camera Uploads/2026/a.jpg", all.getValue(9001).relativePath)
    }

    @Test
    fun `counting by state ignores the others`() {
        records.put(record(1, state = UploadState.DONE), "external_primary")
        records.put(record(2, state = UploadState.FAILED), "external_primary")
        records.put(record(3, state = UploadState.FAILED), "external_primary")
        assertEquals(1, records.countInState(UploadState.DONE))
        assertEquals(2, records.countInState(UploadState.FAILED))
    }

    @Test
    fun `a watermark starts at the beginning and survives a write`() {
        assertEquals(Watermark.BEGINNING, records.watermark("external_primary"))
        records.setWatermark("external_primary", Watermark(42, 1_700_000_000))
        assertEquals(Watermark(42, 1_700_000_000), records.watermark("external_primary"))
    }

    @Test
    fun `watermarks are per volume`() {
        records.setWatermark("external_primary", Watermark(1, 1))
        records.setWatermark("sdcard", Watermark(2, 2))
        assertEquals(1, records.watermark("external_primary").generation)
        assertEquals(2, records.watermark("sdcard").generation)
    }

    @Test
    fun `remembered folders come back and do not duplicate`() {
        records.rememberDirs(setOf("a/", "b/"))
        records.rememberDirs(setOf("b/", "c/"))
        assertEquals(setOf("a/", "b/", "c/"), records.knownDirs())
    }
}
