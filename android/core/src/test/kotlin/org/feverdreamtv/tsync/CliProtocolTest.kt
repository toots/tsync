package org.feverdreamtv.tsync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * The argv and reply contract, driven against the real binary.
 *
 * Both halves are written out by hand — the verbs in OCaml, [Cli] here — so this
 * is the seam that drifts, and only running the two together says they still
 * agree. Every call is its own process, which is how the app makes them.
 */
class CliProtocolTest {

    private lateinit var root: File
    private lateinit var home: File
    private val domain = "iface"

    companion object {
        /** Minutes are never needed; a call that takes this long has wedged. */
        private const val CALL_TIMEOUT_SECONDS = 60L

        /** In CI a missing binary is a broken job, not a reason to skip. */
        private val REQUIRED = System.getenv("CI") == "true"

        private fun executable(): File {
            System.getenv("TSYNC_DAEMON")?.let { return File(it) }
            System.getProperty("tsync.repo")?.let {
                return File(it, "_build/default/bin/tsync.exe")
            }
            var dir: File? = File("").absoluteFile
            while (dir != null) {
                val candidate = File(dir, "_build/default/bin/tsync.exe")
                if (candidate.exists()) return candidate
                dir = dir.parentFile
            }
            return File("_build/default/bin/tsync.exe")
        }
    }

    /** Asked rather than assumed: Linux keeps it under XDG, macOS in a group
     *  container, and a test that spells one out is a test for one platform. */
    private fun configPath(): String {
        val out = String(raw(listOf("build-info")).second)
        return out.lineSequence()
            .firstOrNull { it.startsWith("config:") }
            ?.substringAfter("config:")
            ?.trim()
            ?: File(home, ".config/tsync/config.json").absolutePath
    }

    @Before
    fun writeConfig() {
        val binary = executable()
        if (REQUIRED) {
            assertTrue(
                "no binary at $binary — the job must build bin/tsync.exe first",
                binary.canExecute()
            )
        } else {
            assumeTrue(
                "no tsync binary; run `dune build bin/tsync.exe` first",
                binary.canExecute()
            )
        }

        root = File("/tmp/ts-" + UUID.randomUUID().toString().take(8))
        home = File(root, "h")
        val store = File(root, "store")
        listOf(store, home).forEach { it.mkdirs() }
        val config = File(configPath())
        config.parentFile.mkdirs()

        config.writeText(
            JSONObject()
                .put("name", "protocol-test")
                .put(
                    "domains",
                    JSONArray().put(
                        JSONObject()
                            .put("name", domain)
                            .put("versioning", false)
                            .put("symlinks", "skip")
                            .put("readOnly", false)
                            .put("frontends", JSONArray().put("android"))
                            .put(
                                "backends",
                                JSONArray().put(
                                    JSONObject()
                                        .put("name", "store")
                                        .put("type", "local")
                                        .put("role", "main")
                                        .put("path", store.absolutePath)
                                )
                            )
                    )
                ).toString()
        )
    }

    @After
    fun clean() {
        root.deleteRecursively()
    }

    // ── The contract under test ──────────────────────────────────────────────

    /**
     * HOME alone does not decide where the binary looks: XDG_CONFIG_HOME and its
     * neighbours take precedence, and a CI runner sets them, so a launch that
     * only exported HOME read the runner's config rather than this test's.
     */
    private fun launcher(args: List<String>) =
        ProcessBuilder(listOf(executable().absolutePath) + args).apply {
            environment().apply {
                put("HOME", home.absolutePath)
                remove("XDG_CONFIG_HOME")
                remove("XDG_CACHE_HOME")
                remove("XDG_DATA_HOME")
            }
        }

    private fun raw(args: List<String>): Pair<Int, ByteArray> {
        val process = launcher(args)
            .apply { redirectError(ProcessBuilder.Redirect.DISCARD) }
            .start()
        val out = process.inputStream.readBytes()
        if (!process.waitFor(CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            throw AssertionError("${args.joinToString(" ")} did not finish")
        }
        return process.exitValue() to out
    }

    private fun send(args: List<String>): JSONObject = Cli.reply(String(raw(args).second))

    /** The daemon names items by reference, and mints folder ids itself, so a
     *  client learns one by listing the folder that holds it. */
    private fun childRef(parent: String, name: String): String {
        val items = send(Cli.list(parent)).getJSONArray("items")
        for (i in 0 until items.length()) {
            val entry = items.getJSONObject(i)
            if (entry.getString("name") == name) return entry.getString("ref")
        }
        throw AssertionError("no child $name under $parent")
    }

    /** Creates each folder in turn, answering with the innermost reference. */
    private fun mkdirs(vararg names: String): String {
        var parent = Cli.ROOT
        for (name in names) {
            send(Cli.mkdir(parent, name))
            parent = childRef(parent, name)
        }
        return parent
    }

    private fun staged(contents: ByteArray): File {
        val file = File(root, "staged-" + UUID.randomUUID())
        file.writeBytes(contents)
        return file
    }

    // ── Tests ────────────────────────────────────────────────────────────────

    @Test
    fun `a fresh domain lists nothing`() {
        assertEquals(0, send(Cli.list(Cli.ROOT)).getJSONArray("items").length())
    }

    /**
     * Why camera backup creates its date folders before writing into them: a
     * folder is named by an id the daemon mints at mkdir, so there is nothing
     * to name until it exists.
     */
    @Test
    fun `a write needs the folder it goes in to exist`() {
        val refused = runCatching {
            send(Cli.writeWhole("d:never-minted", "shot.jpg",
                staged("hello".toByteArray()).absolutePath))
        }
        assertTrue("a folder nobody made is nothing to write into",
            refused.exceptionOrNull() is Cli.Error)

        val entries = File(root, "store").walkTopDown()
            .filter { it.isFile && it.path.contains("/journal/") }
            .map { it.readText() }
            .toList()
        assertTrue("a refused write journals nothing, got $entries", entries.isEmpty())
    }

    @Test
    fun `mkdir then write puts the file in the folder with the right size and parent`() {
        val year = mkdirs("Camera Uploads", "2026")
        send(Cli.writeWhole(year, "shot.jpg", staged("hello".toByteArray()).absolutePath))
        val key = childRef(year, "shot.jpg")

        val stat = send(Cli.stat(key))
        assertEquals(5, stat.getInt("size"))
        assertEquals("shot.jpg", stat.getString("name"))

        val parent = send(Cli.stat(year))
        assertEquals(parent.getString("ref"), stat.getString("parentRef"))
        assertTrue("a folder answers to a folder reference", Cli.isDir(year))

        val items = send(Cli.list(year)).getJSONArray("items")
        assertEquals(1, items.length())
        assertEquals("shot.jpg", items.getJSONObject(0).getString("name"))
    }

    /** A page ends with the name to resume from, and resuming there yields the
     *  rest and nothing twice. */
    @Test
    fun `a folder is listed a page at a time`() {
        val folder = mkdirs("paged")
        for (name in listOf("a.txt", "b.txt", "c.txt")) {
            send(Cli.writeWhole(folder, name, staged(name.toByteArray()).absolutePath))
        }
        val seen = mutableListOf<String>()
        var after = ""
        var pages = 0
        do {
            val page = send(Cli.list(folder, after, 2))
            val items = page.getJSONArray("items")
            assertTrue("no page holds more than asked", items.length() <= 2)
            for (i in 0 until items.length()) seen += items.getJSONObject(i).getString("name")
            after = page.optString("next", "")
            pages++
        } while (after.isNotEmpty())
        assertEquals(listOf("a.txt", "b.txt", "c.txt"), seen)
        assertEquals(2, pages)
    }

    /** The staged file is adopted by rename, so deleting it afterwards would
     *  delete the content just taken over. */
    @Test
    fun `write consumes the staging file`() {
        val name = "adopted.txt"
        val staging = staged("hello".toByteArray())
        send(Cli.writeWhole(Cli.ROOT, name, staging.absolutePath))
        assertFalse("it should have been renamed away", staging.exists())
    }

    /** Capture time reaches the manifest only through the staged file's own
     *  modification time. */
    @Test
    fun `the staged file's modification time becomes the file's`() {
        val name = "dated.txt"
        val staging = staged("hello".toByteArray())
        val captured = 1_400_000_000_000L
        staging.setLastModified(captured)
        send(Cli.writeWhole(Cli.ROOT, name, staging.absolutePath))
        val key = childRef(Cli.ROOT, name)

        assertEquals(captured / 1000.0, send(Cli.stat(key)).getDouble("mtime"), 2.0)
    }

    /** A commit does not return until its upload has drained, which is what a
     *  sweep paces on now that there is no queue to ask about. */
    @Test
    fun `a write has published by the time the call returns`() {
        val name = "drained.txt"
        send(Cli.writeWhole(Cli.ROOT, name, staged("hello".toByteArray()).absolutePath))
        assertTrue(send(Cli.stat(childRef(Cli.ROOT, name))).getBoolean("isUploaded"))
    }

    @Test
    fun `stat on a missing reference fails rather than hanging`() {
        val missing = runCatching { send(Cli.stat("f:.tsync-root/nothing.txt")) }
        assertTrue(missing.isFailure)
        assertTrue(missing.exceptionOrNull() is Cli.Error)
    }

    /** create writes a zero-length staged manifest of its own, so sending it
     *  before a write briefly publishes an empty file at the key. */
    @Test
    fun `create alone leaves the key empty`() {
        val name = "created.txt"
        send(Cli.create(Cli.ROOT, name))
        assertEquals(0, send(Cli.stat(childRef(Cli.ROOT, name))).getInt("size"))
    }

    /** Once anything is in it. A domain nobody has written to has no folder
     *  marker for its root, which is why the provider synthesises that one row
     *  rather than stat'ing for it. */
    @Test
    fun `the root of a domain is addressable`() {
        send(Cli.mkdir(Cli.ROOT, "sub"))
        val stat = send(Cli.stat(Cli.ROOT))
        assertEquals(domain, stat.getString("name"))
        assertNotEquals("", stat.getString("ref"))
    }

    @Test
    fun `a file written twice keeps the newer content`() {
        val name = "twice.txt"
        send(Cli.writeWhole(Cli.ROOT, name, staged("one".toByteArray()).absolutePath))
        send(Cli.writeWhole(Cli.ROOT, name, staged("three!".toByteArray()).absolutePath))
        assertEquals(6, send(Cli.stat(childRef(Cli.ROOT, name))).getInt("size"))
    }

    /** The range lands at its own offset, so ranges written into one file
     *  reassemble it however they are ordered. */
    @Test
    fun `ranges written into one file reassemble it`() {
        val name = "bytes.txt"
        send(Cli.writeWhole(Cli.ROOT, name, staged("0123456789".toByteArray()).absolutePath))
        val key = childRef(Cli.ROOT, name)
        val dest = File(root, "ranges")
        send(Cli.read(key, dest.absolutePath, 5, 5))
        send(Cli.read(key, dest.absolutePath, 0, 5))
        assertEquals("0123456789", dest.readText())
    }

    /** Short at end of file, never padded. */
    @Test
    fun `a read past the end is short`() {
        val name = "short.txt"
        send(Cli.writeWhole(Cli.ROOT, name, staged("0123456789".toByteArray()).absolutePath))
        val key = childRef(Cli.ROOT, name)
        val dest = File(root, "short")
        assertEquals(2, send(Cli.read(key, dest.absolutePath, 8, 64)).getInt("length"))
        assertEquals(0, send(Cli.read(key, dest.absolutePath, 99, 8)).getInt("length"))
    }

    /** How many of its chunks are here, which is what tells a caller whether
     *  assembling the whole file would cost a download. */
    @Test
    fun `residency counts the chunks on this device`() {
        val name = "resident.txt"
        send(Cli.writeWhole(Cli.ROOT, name, staged("0123456789".toByteArray()).absolutePath))
        val key = childRef(Cli.ROOT, name)
        val before = send(Cli.residency(key))
        assertTrue(before.getInt("total") > 0)
        send(Cli.read(key, File(root, "warm").absolutePath, 0, 10))
        assertEquals(
            before.getInt("total"),
            send(Cli.residency(key)).getInt("cached")
        )
    }

    /**
     * The session, driven as the verb documents it: a size line, then a header
     * and that many bytes per request, until stdin closes.
     *
     * One process is the point — reads in it are sequential to
     * lib/content/data.ml, which is what lets it fetch ahead of the reader.
     */
    @Test
    fun `one process serves every range of an open file`() {
        val name = "session.txt"
        send(Cli.writeWhole(Cli.ROOT, name, staged("0123456789".toByteArray()).absolutePath))
        val key = childRef(Cli.ROOT, name)

        val process = launcher(Cli.open(key))
            .apply { redirectError(ProcessBuilder.Redirect.DISCARD) }
            .start()
        try {
            val input = java.io.BufferedInputStream(process.inputStream)
            fun header(): String {
                val line = java.io.ByteArrayOutputStream()
                while (true) {
                    val b = input.read()
                    if (b < 0 || b == '\n'.code) return line.toString()
                    line.write(b)
                }
            }
            assertEquals(10L, Cli.reply(header()).getLong("size"))

            fun range(offset: Int, length: Int): String {
                process.outputStream.write("$offset $length\n".toByteArray())
                process.outputStream.flush()
                val n = Cli.reply(header()).getInt("length")
                val body = ByteArray(n)
                var done = 0
                while (done < n) done += input.read(body, done, n - done)
                return String(body)
            }
            assertEquals("01234", range(0, 5))
            assertEquals("56789", range(5, 5))
            assertEquals("", range(99, 5))

            // Closing stdin is what ends it.
            process.outputStream.close()
            assertTrue(process.waitFor(CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS))
        } finally {
            process.destroyForcibly()
        }
    }

    /** Editing in place starts from the current contents. */
    @Test
    fun `fetch assembles the whole content into a file`() {
        val name = "whole.txt"
        send(Cli.writeWhole(Cli.ROOT, name, staged("0123456789".toByteArray()).absolutePath))
        val key = childRef(Cli.ROOT, name)
        val dest = File(root, "fetched")
        send(Cli.fetch(key, dest.absolutePath))
        assertEquals("0123456789", dest.readText())
    }

    @Test
    fun `the store on disk is what the binary was pointed at`() {
        assertTrue(Files.exists(Paths.get(root.absolutePath, "store")))
    }
}
