package org.feverdreamtv.tsync.backup

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The selection and projection, against the real MediaStore.
 *
 * None of this can be exercised off a device: Robolectric has no media provider,
 * so the planner is kept free of cursors and only what talks to one is tested
 * here.
 */
@RunWith(AndroidJUnit4::class)
class MediaScanTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val resolver = context.contentResolver
    private val inserted = mutableListOf<Uri>()

    private val volume = MediaStore.VOLUME_EXTERNAL_PRIMARY

    @After
    fun cleanUp() {
        inserted.forEach { runCatching { resolver.delete(it, null, null) } }
    }

    private fun insert(
        name: String,
        relativePath: String = "DCIM/Camera",
        pending: Boolean = false,
        bytes: ByteArray = ByteArray(64) { 7 }
    ): Uri {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, if (pending) 1 else 0)
        }
        val uri = requireNotNull(
            resolver.insert(MediaStore.Images.Media.getContentUri(volume), values)
        )
        inserted.add(uri)
        if (!pending) {
            resolver.openOutputStream(uri).use { it!!.write(bytes) }
        }
        return uri
    }

    private fun scan(): List<MediaRow> = MediaScan.query(
        context,
        volume,
        MediaScan.collections(volume).first { !it.isVideo },
        Watermark.BEGINNING,
        lookbackSeconds = 0
    )

    @Test
    fun findsACameraCapture() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        val name = "tsync-test-${System.nanoTime()}.jpg"
        insert(name)

        val found = scan().filter { it.displayName == name }
        assertEquals(1, found.size)
        assertEquals(64, found.single().sizeBytes)
    }

    /** Screenshots and downloads are not the camera roll. */
    @Test
    fun ignoresMediaOutsideDcim() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        val name = "tsync-test-shot-${System.nanoTime()}.jpg"
        insert(name, relativePath = "Pictures/Screenshots")

        assertTrue(scan().none { it.displayName == name })
    }

    /** An OEM camera writing to its own DCIM directory is still the camera. */
    @Test
    fun findsCapturesInOemDcimDirectories() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        val name = "tsync-test-oem-${System.nanoTime()}.jpg"
        insert(name, relativePath = "DCIM/100ANDRO")

        assertTrue(scan().any { it.displayName == name })
    }

    /** The camera inserts the row before the bytes land, and a half-written
     *  video taken for a whole one is recorded as done forever. */
    @Test
    fun reportsAStillWritingCaptureAsPending() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        val name = "tsync-test-pending-${System.nanoTime()}.jpg"
        insert(name, pending = true)

        val found = scan().filter { it.displayName == name }
        assumeTrue("a pending row is not always visible to its owner", found.isNotEmpty())
        assertTrue(found.single().isPending)
    }

    @Test
    fun aWatermarkAheadOfEverythingFindsNothingNew() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
        insert("tsync-test-${System.nanoTime()}.jpg")

        val ahead = Watermark(MediaScan.currentGeneration(context, volume) + 1, 0)
        val found = MediaScan.query(
            context, volume,
            MediaScan.collections(volume).first { !it.isVideo },
            ahead, lookbackSeconds = 0
        )
        assertTrue(found.isEmpty())
    }

    @Test
    fun namesTheVolumesItCanSweep() {
        assertTrue(MediaScan.volumes(context).isNotEmpty())
    }
}
