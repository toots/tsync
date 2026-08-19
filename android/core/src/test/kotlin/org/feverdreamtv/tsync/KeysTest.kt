package org.feverdreamtv.tsync

import org.junit.Assert.assertEquals
import org.junit.Test

class KeysTest {

    private val root = Keys.root("photos")

    @Test
    fun `the root is the domain prefix the daemon uses`() {
        assertEquals("tsync/photos/manifests/", root)
    }

    @Test
    fun `ancestors are outermost first and exclude the root and the file`() {
        assertEquals(
            listOf(
                "tsync/photos/manifests/Camera Uploads/",
                "tsync/photos/manifests/Camera Uploads/2026/"
            ),
            Keys.ancestors(root, root + "Camera Uploads/2026/shot.jpg")
        )
    }

    @Test
    fun `a file at the root has no ancestors to create`() {
        assertEquals(emptyList<String>(), Keys.ancestors(root, root + "shot.jpg"))
    }

    @Test
    fun `a directory key excludes itself`() {
        assertEquals(
            listOf("tsync/photos/manifests/Camera Uploads/"),
            Keys.ancestors(root, root + "Camera Uploads/2026/")
        )
    }

    @Test
    fun `a leaf cannot introduce a separator`() {
        assertEquals(".._.._etc_passwd", Keys.sanitizeLeaf("../../etc/passwd"))
        assertEquals("a_b", Keys.sanitizeLeaf("a\\b"))
    }

    @Test
    fun `a leaf keeps its inner spaces but not trailing space or dot`() {
        assertEquals("2026-08-16 12.31.04.jpg", Keys.sanitizeLeaf("2026-08-16 12.31.04.jpg"))
        assertEquals("shot", Keys.sanitizeLeaf("  shot . "))
    }

    @Test
    fun `an empty leaf is still a name`() {
        assertEquals("unnamed", Keys.sanitizeLeaf(""))
        assertEquals("unnamed", Keys.sanitizeLeaf("   "))
    }
}
