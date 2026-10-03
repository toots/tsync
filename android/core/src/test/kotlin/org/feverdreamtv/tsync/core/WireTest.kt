package org.feverdreamtv.tsync.core

import org.json.JSONObject
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.TestInstance
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** The bridge's `request` through `tsync android request JSON`, one process per call (android.md §7). */
private class ProcessCore(private val binary: String, private val home: File, private val config: String) : Core {
    private fun run(vararg arguments: String): String {
        val builder = ProcessBuilder(binary, "android", *arguments).redirectErrorStream(false)
        builder.environment().apply {
            keys.filter { it.startsWith("XDG_") || it.startsWith("TSYNC_") }.forEach(::remove)
            put("HOME", home.path)
            // The desktop binary looks for its config file in a per-platform place; the text itself is portable.
            put("TSYNC_CONFIG_JSON", config)
        }
        val process = builder.start()
        process.outputStream.close()
        val errors = Thread { process.errorStream.readBytes() }.also { it.start() }
        val output = process.inputStream.readBytes().toString(Charsets.UTF_8)
        check(process.waitFor(120, TimeUnit.SECONDS)) { "tsync android ${arguments.first()} did not exit" }
        errors.join()
        check(output.isNotBlank()) { "tsync android ${arguments.joinToString(" ")} printed nothing (exit ${process.exitValue()})" }
        return output
    }

    override fun request(json: String): String = run("request", json)
    override fun status(): String = run("status")
    override fun checkConfig(domain: String, candidate: String?): String? = null
    override fun boot(domain: String): String? = null
    override fun open(ref: String): Long = error("not driven by the wire suite")
    override fun size(handle: Long): Long = error("not driven by the wire suite")
    override fun read(handle: Long, offset: Long, length: Int, dest: ByteArray): Int = error("not driven by the wire suite")
    override fun close(handle: Long): Int = error("not driven by the wire suite")
}

/**
 * The request and reply shapes against a real owner, so the two sides cannot drift (app §12).
 * Skipped, loudly, only when TSYNC_BIN is unset; the build fails when it is set and nothing ran.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class WireTest {
    private val binary: String? = System.getenv("TSYNC_BIN")
    private lateinit var home: File
    private lateinit var core: Core
    private lateinit var client: Client
    private lateinit var ingest: Ingest

    @BeforeAll
    fun owner() {
        if (binary == null) {
            System.err.println("*** WireTest skipped: TSYNC_BIN is unset ***")
            assumeTrue(false, "TSYNC_BIN is unset")
        }
        check(File(binary!!).canExecute()) { "TSYNC_BIN=$binary is not an executable" }
        home = Files.createTempDirectory("tsync-wire").toFile()
        val store = File(home, "store").apply { mkdirs() }
        val backend = JSONObject().put("type", "local").put("name", "store").put("role", "main").put("path", store.path)
        val domain = JSONObject().put("name", "Wire Suite").put("versioning", true).put("symlinks", "skip")
            .put("frontends", listOf("android")).put("backends", listOf(backend))
        val config = JSONObject().put("name", "wire").put("domains", listOf(domain)).toString()
        core = ProcessCore(binary, home, config)
        client = Client(core)
        ingest = Ingest(client, IntentStore(home))
    }

    private fun save(parent: String, name: String, body: String, modified: Long? = null): Committed {
        val staging = ingest.stage(Target.Child(parent, name), exclusive = true, modified = modified)
        ingest.staging(staging).writeText(body)
        ingest.markReady(staging)
        return ingest.commit(staging).also { assertFalse(ingest.staging(staging).exists(), "the staging file is adopted") }
    }

    @Test
    fun theRootRow() {
        val root = client.stat(Parameters.ROOT)
        assertEquals(Parameters.ROOT to Parameters.ROOT, root.ref to root.parentRef)
        assertEquals(Kind.DIR to "Wire Suite", root.kind to root.name)
        assertFalse(root.readOnly)
    }

    @Test
    fun mutationsAnswerTheResultingItem() {
        val folder = client.mkdir(Parameters.ROOT, "mutations", exclusive = true)
        assertTrue(folder.isDir && folder.ref.startsWith("d:") && folder.parentRef == Parameters.ROOT)
        assertEquals(folder.ref, client.mkdir(Parameters.ROOT, "mutations", exclusive = false).ref)
        val taken = assertFailsWith<CoreException> { client.mkdir(Parameters.ROOT, "mutations", exclusive = true) }
        assertEquals(Code.EXISTS, taken.code)
        assertEquals(folder.ref, taken.occupant?.ref)
        val empty = client.create(folder.ref, "empty.txt")
        assertEquals(Kind.FILE to 0L, empty.kind to empty.size)
        assertTrue(Regex("i:[0-9a-f]{32}").matches(empty.ref))
        assertEquals(empty.ref, client.statChild(folder.ref, "empty.txt").ref)
        assertEquals(Code.EXISTS, assertFailsWith<CoreException> { client.create(folder.ref, "empty.txt") }.code)
        val renamed = client.rename(empty.ref, folder.ref, "renamed.txt")
        assertEquals(empty.ref to "renamed.txt", renamed.ref to renamed.name)
        val inner = client.mkdir(folder.ref, "inner", exclusive = true)
        assertEquals(inner.ref, client.rename(renamed.ref, inner.ref, "renamed.txt").parentRef)
        assertTrue(Tree.isChild(client, folder.ref, renamed.ref))
        client.delete(client.stat(renamed.ref))
        assertEquals(Code.NOT_FOUND, assertFailsWith<CoreException> { client.stat(renamed.ref) }.code)
        client.delete(inner)
        assertEquals(Code.NOT_FOUND, assertFailsWith<CoreException> { client.stat(inner.ref) }.code)
    }

    @Test
    fun aSaveNeverReplacesAndKeepsItsMtime() {
        val folder = client.mkdir(Parameters.ROOT, "saves", exclusive = true)
        val first = save(folder.ref, "a.txt", "one", modified = 1_755_347_464_000)
        val second = save(folder.ref, "a.txt", "two")
        assertEquals("a.txt" to "a (1).txt", first.item.name to second.item.name)
        assertEquals(1_755_347_464_000, first.item.mtimeMillis)
        assertEquals(3L, first.item.size)
        assertNotNull(first.item.contentId)
        val dest = File(ingest.intents.stagingDirectory, "fetched")
        val fetched = client.ensureCached(first.item.ref, dest.path)
        assertEquals("one", dest.readText())
        assertEquals(first.item.contentId, fetched.contentId)
        val edit = ingest.stage(Target.Existing(first.item.ref, "a.txt"), exclusive = false, base = fetched.contentId)
        ingest.staging(edit).writeText("edited")
        ingest.markReady(edit)
        val edited = ingest.commit(edit).item
        assertEquals(first.item.ref to 6L, edited.ref to edited.size)
    }

    @Test
    fun aListingPagesInNameOrderAndSaysHowFreshItIs() {
        val folder = client.mkdir(Parameters.ROOT, "listing", exclusive = true)
        for (name in listOf("c", "a", "b")) client.mkdir(folder.ref, name, exclusive = true)
        val page = client.listDir(folder.ref, limit = 2, pull = Pull.NOW)
        assertEquals(listOf("a", "b") to "b", page.items.map { it.name } to page.next)
        assertFalse(page.outdated)
        assertNotNull(page.pulledAt)
        assertEquals(listOf("c"), client.listDir(folder.ref, after = page.next, limit = 2).items.map { it.name })
        assertEquals(listOf("a", "b", "c"), client.listAll(folder.ref).items.map { it.name })
        assertEquals(Code.NOT_FOUND, assertFailsWith<CoreException> { client.listAll("d:0000000000000000") }.code)
    }

    @Test
    fun aMoveOntoATakenNameChangesNothing() {
        val folder = client.mkdir(Parameters.ROOT, "moves", exclusive = true)
        val inner = client.mkdir(folder.ref, "inner", exclusive = true)
        val top = save(folder.ref, "same.txt", "top").item
        save(inner.ref, "same.txt", "inner")
        assertEquals(Code.EXISTS, assertFailsWith<CoreException> { client.rename(top.ref, inner.ref, "same.txt") }.code)
        assertEquals(folder.ref, client.stat(top.ref).parentRef)
    }

    @Test
    fun evictRestoreStatusAndPauseAnswerTheirFields() {
        val folder = client.mkdir(Parameters.ROOT, "state", exclusive = true)
        val file = save(folder.ref, "pinned.txt", "pin me").item
        assertEquals(Counts(1, 0), client.restore(folder.ref))
        val pinned = client.stat(file.ref)
        assertEquals(Availability.PINNED, pinned.availability)
        assertNotNull(pinned.pinnedUntil)
        assertEquals(Counts(1, 0), client.evict(folder.ref))
        assertEquals(Availability.ONLINE_ONLY, client.stat(file.ref).availability)
        val status = client.status()
        assertEquals("Wire Suite", status.domain)
        assertFalse(status.readOnly)
        client.retry()
        client.stats()
        assertTrue(core.status().isNotBlank())
    }

    @Test
    fun pauseIsDurableAcrossOwners() {
        assertTrue(client.pause(true))
        assertTrue(client.status().paused, "the next owner process sees the pause (08 §3.3: answered after the state is durable)")
        assertFalse(client.pause(false))
        assertFalse(client.status().paused)
    }

    @Test
    fun refusalsCarryTheirCodes() {
        assertEquals("""{"ok":false,"code":"invalid","error":"invalid JSON"}""", core.request("not json").trim())
        assertEquals(Code.INVALID, assertFailsWith<CoreException> { client.call(JSONObject().put("action", "no_such_action")) }.code)
        assertEquals(Code.INVALID, assertFailsWith<CoreException> { client.call(JSONObject().put("action", "changes_since").put("arg", "|")) }.code)
        assertEquals(Code.INVALID, assertFailsWith<CoreException> { client.stat("tsync/Wire Suite/x") }.code)
        val outside = Files.createTempFile("outside", "").toFile()
        val denied = assertFailsWith<CoreException> { client.writeChild(Parameters.ROOT, "x", outside.path, null, true) }
        assertEquals(Code.DENIED, denied.code)
        assertTrue(outside.exists())
    }
}
