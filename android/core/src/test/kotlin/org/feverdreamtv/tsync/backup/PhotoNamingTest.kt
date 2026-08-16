package org.feverdreamtv.tsync.backup

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.ZoneId

class PhotoNamingTest {

    private val utc = ZoneId.of("UTC")
    private val paris = ZoneId.of("Europe/Paris")

    /** 2026-08-16T12:31:04Z */
    private val capture = 1_786_883_464_000L

    @Test
    fun `names by capture time under a year folder`() {
        assertEquals(
            "Camera Uploads/2026/2026-08-16 12.31.04.jpg",
            PhotoNaming.relativePath(capture, "IMG_1234.JPG", utc)
        )
    }

    @Test
    fun `formats in the given zone, not UTC`() {
        assertEquals(
            "Camera Uploads/2026/2026-08-16 14.31.04.jpg",
            PhotoNaming.relativePath(capture, "IMG_1234.JPG", paris)
        )
    }

    @Test
    fun `a sequence separates captures sharing a second`() {
        assertEquals(
            "Camera Uploads/2026/2026-08-16 12.31.04 (1).jpg",
            PhotoNaming.relativePath(capture, "IMG_1234.JPG", utc, sequence = 1)
        )
    }

    @Test
    fun `keeps the extension the name carries, not one guessed from a type`() {
        assertEquals(".heic", PhotoNaming.extensionOf("IMG_0001.HEIC"))
        assertEquals(".dng", PhotoNaming.extensionOf("IMG_0001.dng"))
        assertEquals(".mp4", PhotoNaming.extensionOf("VID_0001.mp4"))
    }

    @Test
    fun `tolerates a name with no usable extension`() {
        assertEquals("", PhotoNaming.extensionOf("IMG_0001"))
        assertEquals("", PhotoNaming.extensionOf("IMG_0001."))
        assertEquals("", PhotoNaming.extensionOf(".hidden"))
        assertEquals("", PhotoNaming.extensionOf("weird.ex-t"))
    }

    @Test
    fun `a display name cannot forge a path`() {
        val path = PhotoNaming.relativePath(capture, "../../etc/passwd.jpg", utc)
        assertEquals("Camera Uploads/2026/2026-08-16 12.31.04.jpg", path)
        assertEquals(2, path.count { it == '/' })
    }
}
