package org.feverdreamtv.tsync.autofill

import org.junit.Assert.assertEquals
import org.junit.Test

/** passwords §5.1: which password fields ask for a new password, as browser/test/fields.test.js. */
class FormTest {
    @Test
    fun marksPrevail() {
        assertEquals(listOf(false, true), Form.fresh(listOf(false, null)))
        assertEquals(listOf(true), Form.fresh(listOf(true)))
    }

    @Test
    fun aSignInIsNoNewPassword() {
        assertEquals(listOf(false), Form.fresh(listOf(null)))
    }

    @Test
    fun aSignUpAndItsConfirmation() {
        assertEquals(listOf(true, true), Form.fresh(listOf(null, null)))
    }

    @Test
    fun aChangeFormsFirstIsTheCurrentOne() {
        assertEquals(listOf(false, true, true), Form.fresh(listOf(null, null, null)))
    }
}
