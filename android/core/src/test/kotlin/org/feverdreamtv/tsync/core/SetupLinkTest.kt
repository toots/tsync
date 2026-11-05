package org.feverdreamtv.tsync.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SetupLinkTest {
    @Test
    fun aLinkIsToldFromAServerUrl() {
        assertTrue(SetupLink.looksLike("https://h.example/join/0123456789abcdef0123456789abcdef#key"))
        assertFalse(SetupLink.looksLike("https://h.example"))
        assertFalse(SetupLink.looksLike("https://h.example/join/0123"))
    }

    @Test
    fun eachDomainCarriesItsServerAndLook() {
        val answer = SetupLink.parse(
            """{"from":"laptop",
               "domains":[{"name":"Photos","url":"https://a.example","secret":"s1"},
                          {"name":"Home","url":"https://b.example","secret":"s2"}],
               "skipped":[{"name":"Bucket","reason":"its s3 backend cannot be held here"}],
               "about":[{"name":"Photos","extensions":[]},
                        {"name":"Home","extensions":["totp"],"vault":{"color":"#16a34a","icon":"AQID"}}]}""",
        )
        assertIs<SetupAnswer.Opened>(answer)
        assertEquals("laptop", answer.from)
        assertEquals(listOf("Photos", "Home"), answer.domains.map { it.name })
        assertEquals("https://b.example", answer.domains[1].url)
        assertEquals("s2", answer.domains[1].secret)
        assertNull(answer.domains[0].look)
        assertEquals("#16a34a", answer.domains[1].look?.color)
        assertContentEquals(byteArrayOf(1, 2, 3), answer.domains[1].look?.icon)
        assertEquals(listOf("Bucket: its s3 backend cannot be held here"), answer.skipped)
    }

    @Test
    fun theCoreSentenceIsShownAsIs() {
        val answer = SetupLink.parse(FakeCore().setupLink("anything"))
        assertIs<SetupAnswer.Refused>(answer)
        assertEquals("This is not a tsync setup link", answer.reason)
        assertIs<SetupAnswer.Refused>(SetupLink.parse("not json"))
    }
}
