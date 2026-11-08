package org.feverdreamtv.tsync.core

import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ConfigFormatTest {
    private val secret = "0123456789abcdef0123456789abcdef"

    @Test
    fun theConfigIsTheSpecifiedShape() {
        val domains = listOf(ServerConfig("https://tsync.example.org/", secret, "Family Photos"), ServerConfig("https://b.example.org", secret, "docs"))
        val config = JSONObject(ServerConfig.encode("Pixel 9", domains))
        assertEquals(setOf("name", "domains"), config.keySet())
        assertEquals("Pixel 9", config.getString("name"))
        val domain = config.getJSONArray("domains").getJSONObject(0)
        assertEquals(setOf("name", "versioning", "maxCache", "frontends", "backends"), domain.keySet())
        assertEquals("2G", domain.getString("maxCache"))
        assertEquals("android", domain.getJSONArray("frontends").getString(0))
        val backend = domain.getJSONArray("backends").getJSONObject(0)
        assertEquals(setOf("type", "name", "role", "url", "secret"), backend.keySet())
        assertEquals("https://tsync.example.org", backend.getString("url"))
        assertEquals("main", backend.getString("role"))
        assertEquals("docs", config.getJSONArray("domains").getJSONObject(1).getString("name"))
    }
}

class ConfigStoreTest {
    private val home = Files.createTempDirectory("home").toFile()
    private val store = ConfigStore(home)
    private val docs = ServerConfig("https://a.example.org", "0123456789abcdef0123456789abcdef", "docs")
    private val photos = ServerConfig("https://b.example.org", "fedcba9876543210fedcba9876543210", "photos")
    private val accept: (String, String) -> String? = { _, _ -> null }
    private fun files() = File(home, ".config/tsync").list()!!.sorted()

    @Test
    fun anAcceptedCandidateBecomesTheOwnerOnlyConfig() {
        assertFalse(store.exists())
        val checked = mutableListOf<String>()
        assertNull(store.add(listOf(docs, photos), "Pixel") { domain, text ->
            checked += domain
            assertEquals(listOf(docs, photos), ServerConfig.decode(text)?.second)
            null
        })
        assertEquals(listOf("docs", "photos"), checked)
        assertEquals(listOf(docs, photos), store.read())
        assertEquals(listOf("config.json"), files())
        assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(store.file.toPath())))
        assertEquals("rwx------", PosixFilePermissions.toString(Files.getPosixFilePermissions(store.file.parentFile.toPath())))
    }

    @Test
    fun aRefusedCandidateIsNeverTheConfig() {
        assertEquals("docs: nope", store.add(listOf(docs), "Pixel") { _, _ -> "nope" })
        assertFalse(store.exists())
        assertNull(File(home, ".config/tsync").list())
        store.add(listOf(docs), "Pixel", check = accept)
        assertEquals("photos: refused", store.add(listOf(photos), "Pixel") { domain, _ -> "refused".takeIf { domain == "photos" } })
        assertEquals(listOf(docs), store.read())
        assertEquals(listOf("config.json"), files())
    }

    @Test
    fun addingAppendsAndLeavesAKnownDomainAlone() {
        store.add(listOf(docs), "Pixel", check = accept)
        val checked = mutableListOf<String>()
        assertNull(store.add(listOf(docs.copy(url = "https://elsewhere.example.org"), photos), "Other") { domain, _ -> checked += domain; null })
        assertEquals(listOf("photos"), checked)
        assertEquals(listOf(docs, photos), store.read())
        assertEquals("Pixel", JSONObject(store.file.readText()).getString("name"))
    }

    @Test
    fun replacingDropsWhatTheConfigNamed() {
        store.add(listOf(docs), "Pixel", check = accept)
        assertNull(store.add(listOf(photos), "Other", replace = true, check = accept))
        assertEquals(listOf(photos), store.read())
        assertEquals("Pixel", JSONObject(store.file.readText()).getString("name"))
    }

    @Test
    fun removingDeletesOnlyThatEntry() {
        store.add(listOf(docs, photos), "Pixel", check = accept)
        assertEquals("nope", store.remove("docs") { _, _ -> "nope" })
        assertEquals(listOf(docs, photos), store.read())
        assertNull(store.remove("docs") { domain, _ -> assertEquals("photos", domain); null })
        assertEquals(listOf(photos), store.read())
        assertNull(store.remove("photos", accept))
        assertEquals(emptyList(), store.read())
        assertEquals("Pixel", JSONObject(store.file.readText()).getString("name"))
    }

    @Test
    fun onlyAFileThatDoesNotDecodeIsUnreadable() {
        assertFalse(store.unreadable())
        store.add(listOf(docs), "Pixel", check = accept)
        store.remove("docs", accept)
        assertFalse(store.unreadable())
        store.file.writeText("{")
        assertTrue(store.unreadable())
        assertEquals(emptyList(), store.read())
    }

    @Test
    fun readsAnOlderConfig() {
        File(home, ".config/tsync").mkdirs()
        store.file.writeText(
            """{"name":"old phone","domains":[{"name":"docs","versioning":true,"symlinks":"skip","maxCache":1073741824,
               "frontends":["android"],"backends":[{"type":"http-proxy","name":"server","role":"main",
               "url":"http://nas.lan:8080","secret":"short"}]}]}"""
        )
        assertEquals(listOf(ServerConfig("http://nas.lan:8080", "short", "docs", "1073741824")), store.read())
        store.add(listOf(photos), "Pixel", check = accept)
        assertEquals("old phone", JSONObject(store.file.readText()).getString("name"))
        assertEquals(listOf("docs", "photos"), store.names())
    }
}
