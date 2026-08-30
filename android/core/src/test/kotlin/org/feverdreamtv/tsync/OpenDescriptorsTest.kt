package org.feverdreamtv.tsync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OpenDescriptorsTest {

    @Before
    fun start() = OpenDescriptors.reset()

    @Test
    fun `the first descriptor starts the service and the last stops it`() {
        assertTrue("the first crossing is a start", OpenDescriptors.retain())
        assertTrue("the last crossing is a stop", OpenDescriptors.release())
    }

    @Test
    fun `the ones in between say nothing`() {
        assertTrue(OpenDescriptors.retain())
        assertFalse("a second open is already covered", OpenDescriptors.retain())
        assertFalse("and a third", OpenDescriptors.retain())
        assertFalse("one closing leaves two open", OpenDescriptors.release())
        assertFalse("and one open", OpenDescriptors.release())
        assertTrue("the last one is the stop", OpenDescriptors.release())
        assertEquals(0, OpenDescriptors.count)
    }

    /* An open that fails part way gives back what it took, and it is the only
       caller that releases something it never served a read from. */
    @Test
    fun `an open that fails gives back exactly what it took`() {
        assertTrue(OpenDescriptors.retain())
        assertTrue("the failed open closes it again", OpenDescriptors.release())
        assertEquals(0, OpenDescriptors.count)
        assertTrue("and the next open starts the service", OpenDescriptors.retain())
    }

    /* Nothing guarantees a release is paired: a descriptor whose client died
       may be released by a path that already released it. Going negative would
       take two further opens before the service came back, and the reads in
       between would be served by a process free to be frozen. */
    @Test
    fun `a release with nothing open does not go negative`() {
        assertFalse("nothing to give back", OpenDescriptors.release())
        assertEquals(0, OpenDescriptors.count)
        assertTrue("the next open still starts the service", OpenDescriptors.retain())
        assertEquals(1, OpenDescriptors.count)
    }
}
