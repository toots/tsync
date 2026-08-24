package org.feverdreamtv.tsync

import org.junit.Assert.assertEquals
import org.junit.Test

class KeysTest {

    @Test
    fun `the root folder id is the one the daemon reserves`() {
        assertEquals(".tsync-root", Keys.ROOT_FOLDER_ID)
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
