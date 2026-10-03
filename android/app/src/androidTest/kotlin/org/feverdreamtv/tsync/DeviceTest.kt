package org.feverdreamtv.tsync

import android.Manifest
import android.content.ContentValues
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.feverdreamtv.tsync.backup.MediaSource
import org.feverdreamtv.tsync.core.Parameters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * What exists only on a device (10 §3.4). This suite's package carries no core library, so the
 * provider is seen as it is when the core cannot boot.
 */
@RunWith(AndroidJUnit4::class)
class DeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun thereIsAlwaysOneRootEvenWhenTheCoreCannotBoot() {
        val roots = context.contentResolver.query(DocumentsContract.buildRootsUri(Tsync.AUTHORITY), null, null, null, null)
        assertNotNull(roots)
        roots!!.use {
            assertEquals(1, it.count)
            it.moveToFirst()
            assertEquals(Parameters.ROOT, it.getString(it.getColumnIndexOrThrow(DocumentsContract.Root.COLUMN_DOCUMENT_ID)))
            assertEquals("tsync", it.getString(it.getColumnIndexOrThrow(DocumentsContract.Root.COLUMN_TITLE)))
            val flags = it.getInt(it.getColumnIndexOrThrow(DocumentsContract.Root.COLUMN_FLAGS))
            assertTrue(flags and DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD != 0)
        }
    }

    @Test
    fun theRootDocumentIsSynthesised() {
        val root = DocumentsContract.buildDocumentUri(Tsync.AUTHORITY, Parameters.ROOT)
        context.contentResolver.query(root, null, null, null, null)!!.use {
            assertTrue(it.moveToFirst())
            assertEquals(DocumentsContract.Document.MIME_TYPE_DIR, it.getString(it.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)))
        }
    }

    @Test
    fun discoveryFindsACaptureInAnOemSubfolderOfDcim() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val automation = instrumentation.uiAutomation
        automation.grantRuntimePermission(context.packageName, Manifest.permission.READ_MEDIA_IMAGES)
        automation.grantRuntimePermission(context.packageName, Manifest.permission.READ_MEDIA_VIDEO)
        val name = "tsync-device-test-${System.currentTimeMillis()}.jpg"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "DCIM/OemCamera/Burst")
        }
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val inserted = context.contentResolver.insert(collection, values)!!
        try {
            context.contentResolver.openOutputStream(inserted)!!.use { it.write(ByteArray(64) { 1 }) }
            val source = MediaSource(context)
            val row = source.rows(MediaStore.VOLUME_EXTERNAL_PRIMARY, null).single { it.displayName == name }
            assertEquals(64L, row.size)
            assertNotNull(row.generation)
            assertEquals(64, source.open(MediaStore.VOLUME_EXTERNAL_PRIMARY, row).use { it.readBytes().size })
            assertTrue(source.version(MediaStore.VOLUME_EXTERNAL_PRIMARY).isNotEmpty())
        } finally {
            context.contentResolver.delete(inserted, null, null)
        }
    }
}
