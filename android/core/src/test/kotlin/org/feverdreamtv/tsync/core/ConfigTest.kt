package org.feverdreamtv.tsync.core

import com.sun.net.httpserver.HttpServer
import org.json.JSONObject
import java.io.File
import java.net.InetSocketAddress
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ConfigFormTest {
    private val secret = "0123456789abcdef0123456789abcdef"
    private fun form(url: String = "https://tsync.example.org", secret: String = this.secret, domain: String = "Family Photos") =
        ConfigForm.validate(ServerConfig(url, secret, domain))

    @Test
    fun theFirstFailureWinsOnItsField() {
        assertNull(form())
        assertEquals(FormError.URL_CLEARTEXT, form(url = "http://tsync.example.org", secret = "short", domain = ".."))
        assertEquals(FormField.URL, FormError.URL_CLEARTEXT.field)
        assertEquals(FormError.SECRET_TOO_SHORT, form(secret = "0123456789abcdef0123456789abcde", domain = ".."))
        assertEquals(FormError.DOMAIN_INVALID, form(domain = ".."))
    }

    @Test
    fun cleartextOnlyToLoopback() {
        for (url in listOf("http://127.0.0.1:8080", "http://localhost", "http://[::1]:9", "http://127.9.9.9/base"))
            assertNull(ConfigForm.urlError(url), url)
        for (url in listOf("http://192.168.1.4", "http://127.example.org", "http://localhost.example.org", "http://128.0.0.1"))
            assertEquals(FormError.URL_CLEARTEXT, ConfigForm.urlError(url), url)
        for (url in listOf("ftp://x", "tsync.example.org", "https://", "https://u:p@x", "https://x?q=1", "https://x y"))
            assertEquals(FormError.URL_MALFORMED, ConfigForm.urlError(url), url)
    }

    @Test
    fun domainGrammar() {
        for (name in listOf("Family Photos", "chunks", "tsync", "Shares", "é".repeat(127)))
            assertTrue(ConfigForm.isDomainName(name), name)
        for (name in listOf("", ".", "..", "a/b", "a\u0001b", "a\u007fb", ".tsync-x", "shares", "gc-jobs", "é".repeat(128)))
            assertFalse(ConfigForm.isDomainName(name), name)
    }

    @Test
    fun theConfigIsTheSpecifiedShape() {
        val config = JSONObject(ServerConfig("https://tsync.example.org/", secret, "Family Photos").encode("Pixel 9"))
        assertEquals(setOf("name", "domains"), config.keySet())
        assertEquals("Pixel 9", config.getString("name"))
        val domain = config.getJSONArray("domains").getJSONObject(0)
        assertEquals(setOf("name", "versioning", "symlinks", "maxCache", "frontends", "backends"), domain.keySet())
        assertEquals("skip", domain.getString("symlinks"))
        assertEquals("2G", domain.getString("maxCache"))
        assertEquals("android", domain.getJSONArray("frontends").getString(0))
        val backend = domain.getJSONArray("backends").getJSONObject(0)
        assertEquals(setOf("type", "name", "role", "url", "secret"), backend.keySet())
        assertEquals("https://tsync.example.org", backend.getString("url"))
        assertEquals("main", backend.getString("role"))
    }
}

class ConfigStoreTest {
    private val home = Files.createTempDirectory("home").toFile()
    private val store = ConfigStore(home)
    private val good = ServerConfig("https://a.example.org", "0123456789abcdef0123456789abcdef", "docs", "4G")
    private val bad = good.copy(url = "https://b.example.org")
    private fun files() = File(home, ".config/tsync").list()!!.sorted()

    @Test
    fun anAcceptedCandidateBecomesTheOwnerOnlyConfig() {
        assertFalse(store.exists())
        assertNull(store.save(good, "Pixel", check = { domain, text -> assertEquals("docs", domain); assertEquals(good, ServerConfig.decode(text)?.second); null }))
        assertEquals(good, store.read())
        assertEquals(listOf("config.json"), files())
        assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(store.file.toPath())))
        assertEquals("rwx------", PosixFilePermissions.toString(Files.getPosixFilePermissions(store.file.parentFile.toPath())))
    }

    @Test
    fun aRefusedCandidateIsNeverTheConfig() {
        assertEquals("domains[0]: nope", store.save(bad, "Pixel") { _, _ -> "domains[0]: nope" })
        assertFalse(store.exists())
        assertNull(File(home, ".config/tsync").list())
        store.save(good, "Pixel") { _, _ -> null }
        assertEquals("refused", store.save(bad, "Pixel") { _, _ -> "refused" })
        assertEquals(good, store.read())
        assertEquals(listOf("config.json"), files())
    }

    @Test
    fun savingKeepsTheClientNameAndReadsAnOlderConfig() {
        File(home, ".config/tsync").mkdirs()
        store.file.writeText(
            """{"name":"old phone","domains":[{"name":"docs","versioning":true,"symlinks":"skip","maxCache":1073741824,
               "frontends":["android"],"backends":[{"type":"http-proxy","name":"server","role":"main",
               "url":"http://nas.lan:8080","secret":"short"}]}]}"""
        )
        assertEquals(ServerConfig("http://nas.lan:8080", "short", "docs", "1073741824"), store.read())
        store.save(good, "Pixel") { _, _ -> null }
        assertEquals("old phone", JSONObject(store.file.readText()).getString("name"))
    }
}

class CheckServerTest {
    @Test
    fun signsAsTheWireSpecifies() {
        assertEquals(
            "88bfa097567658cbf464de58b53601df613701a09f172016c78f22a9148b3e2d",
            CheckServer.signature("s3cret", "GET", "/domains", "1727600000", ByteArray(0)),
        )
        assertEquals(
            "aaad0b84828445ef41805f42d64c59c051d88f21456c8308b72e691dfbc40ad5",
            CheckServer.signature("s3cret", "PUT", "/o/dHN5bmMvZG9jcy9tYW5pZmVzdHMvYWIvZi0w?if_absent=1", "1727600000", "hello".toByteArray()),
        )
    }

    @Test
    fun answersAreToldApart() {
        val expected = CheckServer.signature("s3cret", "GET", "/domains", "1727600000", ByteArray(0))
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val signed = exchange.requestHeaders.getFirst("x-tsync-signature") == expected &&
                exchange.requestHeaders.getFirst("x-tsync-timestamp") == "1727600000"
            val (status, body) = when {
                exchange.requestURI.path == "/base/domains" && signed -> 200 to """{"domains":[{"name":"docs","readOnly":true},{"name":"b"}]}"""
                exchange.requestURI.path == "/base/domains" -> 401 to ""
                exchange.requestURI.path == "/broken/domains" -> 200 to "<html>"
                else -> 404 to ""
            }
            exchange.sendResponseHeaders(status, body.length.toLong().takeIf { it > 0 } ?: -1)
            if (body.isNotEmpty()) exchange.responseBody.use { it.write(body.toByteArray()) }
            exchange.close()
        }
        server.start()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            assertEquals(
                ServerAnswer.Domains(listOf(ServerDomain("docs", true), ServerDomain("b", false))),
                CheckServer.check("$base/base/", "s3cret", 1727600000),
            )
            assertEquals(ServerAnswer.SecretRefused, CheckServer.check("$base/base", "wrong", 1727600000))
            assertEquals(ServerAnswer.TooOld, CheckServer.check("$base/old", "s3cret", 1727600000))
            assertTrue(CheckServer.check("$base/broken", "s3cret", 1727600000) is ServerAnswer.Failed)
        } finally {
            server.stop(0)
        }
        assertTrue(CheckServer.check("http://127.0.0.1:1", "s3cret") is ServerAnswer.Failed)
    }
}
