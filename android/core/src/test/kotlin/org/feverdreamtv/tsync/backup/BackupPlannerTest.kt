package org.feverdreamtv.tsync.backup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

class BackupPlannerTest {

    private val utc = ZoneId.of("UTC")

    /** 2026-08-16T12:31:04Z, and a "now" well clear of the settle window. */
    private val capture = 1_786_883_464_000L
    private val now = capture + 3_600_000

    private fun row(
        id: Long,
        name: String = "IMG_$id.jpg",
        captureMillis: Long = capture,
        size: Long = 1_000,
        added: Long = capture / 1000,
        modified: Long = capture / 1000,
        pending: Boolean = false
    ) = MediaRow(
        mediaId = id,
        volume = "external_primary",
        displayName = name,
        captureMillis = captureMillis,
        sizeBytes = size,
        addedSeconds = added,
        modifiedSeconds = modified,
        generation = id,
        isVideo = false,
        isPending = pending
    )

    private fun plan(rows: List<MediaRow>, recorded: Map<Long, UploadRecord> = emptyMap()) =
        BackupPlanner.plan(rows, recorded, now, utc)

    private fun uploads(actions: List<BackupAction>) =
        actions.filterIsInstance<BackupAction.Upload>()

    private fun skips(actions: List<BackupAction>) =
        actions.filterIsInstance<BackupAction.Skip>()

    @Test
    fun `a fresh photo is uploaded under its capture date`() {
        val actions = plan(listOf(row(1)))
        assertEquals(1, uploads(actions).size)
        assertEquals(
            "Camera Uploads/2026/2026-08-16 12.31.04.jpg",
            uploads(actions).single().relativePath
        )
    }

    @Test
    fun `a photo already done at the same size and mtime is skipped`() {
        val recorded = mapOf(
            1L to UploadRecord(
                1, "Camera Uploads/2026/2026-08-16 12.31.04.jpg", 1_000,
                capture / 1000, UploadState.DONE
            )
        )
        val actions = plan(listOf(row(1)), recorded)
        assertEquals(SkipReason.ALREADY_DONE, skips(actions).single().reason)
    }

    @Test
    fun `a changed photo is uploaded again, keeping the name it was given`() {
        val frozen = "Camera Uploads/2026/2026-08-16 12.31.04.jpg"
        val recorded = mapOf(
            1L to UploadRecord(1, frozen, 1_000, capture / 1000, UploadState.DONE)
        )
        val actions = plan(listOf(row(1, size = 2_000)), recorded)
        assertEquals(frozen, uploads(actions).single().relativePath)
    }

    @Test
    fun `a failed record is retried under the same name`() {
        val frozen = "Camera Uploads/2026/2026-08-16 12.31.04.jpg"
        val recorded = mapOf(
            1L to UploadRecord(1, frozen, 1_000, capture / 1000, UploadState.FAILED)
        )
        assertEquals(frozen, uploads(plan(listOf(row(1)), recorded)).single().relativePath)
    }

    @Test
    fun `two captures in one second get distinct names`() {
        val actions = plan(listOf(row(1), row(2)))
        val names = uploads(actions).map { it.relativePath }
        assertEquals(2, names.toSet().size)
        assertTrue(names.any { it.endsWith("12.31.04.jpg") })
        assertTrue(names.any { it.endsWith("12.31.04 (1).jpg") })
    }

    @Test
    fun `a still-writing capture is skipped, not taken as a whole file`() {
        val actions = plan(listOf(row(1, pending = true)))
        assertEquals(SkipReason.STILL_PENDING, skips(actions).single().reason)
    }

    @Test
    fun `a capture that changed a moment ago is left to settle`() {
        val actions = BackupPlanner.plan(
            listOf(row(1, modified = now / 1000)), emptyMap(), now, utc
        )
        assertEquals(SkipReason.UNSETTLED, skips(actions).single().reason)
    }

    @Test
    fun `an empty row is skipped`() {
        assertEquals(SkipReason.EMPTY, skips(plan(listOf(row(1, size = 0)))).single().reason)
    }

    /**
     * A rebuilt MediaProvider renumbers every id, so nothing matches by id and a
     * naive planner re-uploads the whole roll.
     */
    @Test
    fun `renumbered ids are recognised by name and size`() {
        val recorded = mapOf(
            1L to UploadRecord(
                1, "Camera Uploads/2026/2026-08-16 12.31.04.jpg", 1_000,
                capture / 1000, UploadState.DONE
            )
        )
        val actions = plan(listOf(row(9_001)), recorded)
        assertEquals(SkipReason.ALREADY_DONE, skips(actions).single().reason)
    }

    @Test
    fun `a renumbered id whose content differs is uploaded, not mistaken for the old one`() {
        val recorded = mapOf(
            1L to UploadRecord(
                1, "Camera Uploads/2026/2026-08-16 12.31.04.jpg", 1_000,
                capture / 1000, UploadState.DONE
            )
        )
        val actions = plan(listOf(row(9_001, size = 4_242)), recorded)
        assertEquals(
            "Camera Uploads/2026/2026-08-16 12.31.04 (1).jpg",
            uploads(actions).single().relativePath
        )
    }

    /**
     * The watermark is cut against DATE_ADDED, so advancing it by the usually
     * larger DATE_MODIFIED would carry it past captures never looked at — which
     * a backup reports as nothing to do.
     */
    @Test
    fun `the watermark advances by date added, never by date modified`() {
        val edited = row(1, added = 1_000, modified = 9_000)
        assertEquals(1_000, BackupPlanner.advanceWatermark(0, edited))
    }

    @Test
    fun `the watermark never goes backwards`() {
        assertEquals(5_000, BackupPlanner.advanceWatermark(5_000, row(1, added = 1_000)))
    }

    @Test
    fun `planning is stable across repeated sweeps`() {
        val rows = listOf(row(1), row(2), row(3))
        assertEquals(
            uploads(plan(rows)).map { it.relativePath },
            uploads(plan(rows)).map { it.relativePath }
        )
    }
}
