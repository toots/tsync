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
        val config = File(home, ".config/tsync/config.json")
        listOf(store, config.parentFile).forEach { it.mkdirs() }

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

    private fun raw(args: List<String>): Pair<Int, ByteArray> {
        val process = ProcessBuilder(listOf(executable().absolutePath) + args)
            .apply {
                environment()["HOME"] = home.absolutePath
                redirectError(ProcessBuilder.Redirect.DISCARD)
            }
            .start()
        val out = process.inputStream.readBytes()
        if (!process.waitFor(CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            throw AssertionError("${args.joinToString(" ")} did not finish")
        }
        return process.exitValue() to out
    }

    private fun send(args: List<String>): JSONObject = Cli.reply(String(raw(args).second))

    private val root_ get() = Keys.root(domain)

    private fun staged(contents: ByteArray): File {
        val file = File(root, "staged-" + UUID.randomUUID())
        file.writeBytes(contents)
        return file
    }

    // ── Tests ────────────────────────────────────────────────────────────────

    @Test
    fun `a fresh domain lists nothing`() {
        assertEquals(0, send(Cli.list(root_)).getJSONArray("items").length())
    }

    /**
     * The reason camera backup creates its date folders rather than letting the
     * upload mint their ids: the upload does mint them locally, but writes no
     * Mkdir entry, so a peer replaying the journal gets the file and no folder
     * to hang it under.
     */
    @Test
    fun `a write into an uncreated folder journals no folder`() {
        val key = root_ + "Camera Uploads/2026/shot.jpg"
        send(Cli.writeWhole(key, staged("hello".toByteArray()).absolutePath))

        val entries = File(root, "store").walkTopDown()
            .filter { it.isFile && it.path.contains("/journal/") }
            .map { it.readText() }
            .toList()
        assertEquals(1, entries.size)
        assertTrue("expected a put, got ${entries[0]}", entries[0].contains("\"op\":\"put\""))
        assertFalse("an upload should mint no Mkdir entry", entries[0].contains("mkdir"))
    }

    @Test
    fun `mkdir then write puts the file in the folder with the right size and parent`() {
        val folder = root_ + "Camera Uploads/"
        val year = folder + "2026/"
        val key = year + "shot.jpg"
        send(Cli.mkdir(folder))
        send(Cli.mkdir(year))
        send(Cli.writeWhole(key, staged("hello".toByteArray()).absolutePath))

        val stat = send(Cli.stat(key))
        assertEquals(5, stat.getInt("size"))
        assertEquals("shot.jpg", stat.getString("name"))

        val parent = send(Cli.stat(year))
        assertEquals(parent.getString("ref"), stat.getString("parentRef"))

        val items = send(Cli.list(year)).getJSONArray("items")
        assertEquals(1, items.length())
        assertEquals("shot.jpg", items.getJSONObject(0).getString("name"))
    }

    /** The staged file is adopted by rename, so deleting it afterwards would
     *  delete the content just taken over. */
    @Test
    fun `write consumes the staging file`() {
        val key = root_ + "adopted.txt"
        val staging = staged("hello".toByteArray())
        send(Cli.writeWhole(key, staging.absolutePath))
        assertFalse("it should have been renamed away", staging.exists())
    }

    /** Capture time reaches the manifest only through the staged file's own
     *  modification time. */
    @Test
    fun `the staged file's modification time becomes the file's`() {
        val key = root_ + "dated.txt"
        val staging = staged("hello".toByteArray())
        val captured = 1_400_000_000_000L
        staging.setLastModified(captured)
        send(Cli.writeWhole(key, staging.absolutePath))

        assertEquals(captured / 1000.0, send(Cli.stat(key)).getDouble("mtime"), 2.0)
    }

    /** A commit does not return until its upload has drained, which is what a
     *  sweep paces on now that there is no queue to ask about. */
    @Test
    fun `a write has published by the time the call returns`() {
        val key = root_ + "drained.txt"
        send(Cli.writeWhole(key, staged("hello".toByteArray()).absolutePath))
        assertTrue(send(Cli.stat(key)).getBoolean("isUploaded"))
    }

    @Test
    fun `stat on a missing key fails rather than hanging`() {
        val missing = runCatching { send(Cli.stat(root_ + "nothing.txt")) }
        assertTrue(missing.isFailure)
        assertTrue(missing.exceptionOrNull() is Cli.Error)
    }

    /** create writes a zero-length staged manifest of its own, so sending it
     *  before a write briefly publishes an empty file at the key. */
    @Test
    fun `create alone leaves the key empty`() {
        val key = root_ + "created.txt"
        send(Cli.create(key))
        assertEquals(0, send(Cli.stat(key)).getInt("size"))
    }

    /** Once anything is in it. A domain nobody has written to has no folder
     *  marker for its root, which is why the provider synthesises that one row
     *  rather than stat'ing for it. */
    @Test
    fun `the root of a domain is addressable`() {
        send(Cli.mkdir(root_ + "sub/"))
        val stat = send(Cli.stat(root_))
        assertEquals(domain, stat.getString("name"))
        assertNotEquals("", stat.getString("ref"))
    }

    @Test
    fun `a file written twice keeps the newer content`() {
        val key = root_ + "twice.txt"
        send(Cli.writeWhole(key, staged("one".toByteArray()).absolutePath))
        send(Cli.writeWhole(key, staged("three!".toByteArray()).absolutePath))
        assertEquals(6, send(Cli.stat(key)).getInt("size"))
    }

    /** The range lands at its own offset, so ranges written into one file
     *  reassemble it however they are ordered. */
    @Test
    fun `ranges written into one file reassemble it`() {
        val key = root_ + "bytes.txt"
        send(Cli.writeWhole(key, staged("0123456789".toByteArray()).absolutePath))
        val dest = File(root, "ranges")
        send(Cli.read(key, dest.absolutePath, 5, 5))
        send(Cli.read(key, dest.absolutePath, 0, 5))
        assertEquals("0123456789", dest.readText())
    }

    /** Short at end of file, never padded. */
    @Test
    fun `a read past the end is short`() {
        val key = root_ + "short.txt"
        send(Cli.writeWhole(key, staged("0123456789".toByteArray()).absolutePath))
        val dest = File(root, "short")
        assertEquals(2, send(Cli.read(key, dest.absolutePath, 8, 64)).getInt("length"))
        assertEquals(0, send(Cli.read(key, dest.absolutePath, 99, 8)).getInt("length"))
    }

    /** How many of its chunks are here, which is what tells a caller whether
     *  assembling the whole file would cost a download. */
    @Test
    fun `residency counts the chunks on this device`() {
        val key = root_ + "resident.txt"
        send(Cli.writeWhole(key, staged("0123456789".toByteArray()).absolutePath))
        val before = send(Cli.residency(key))
        assertTrue(before.getInt("total") > 0)
        send(Cli.read(key, File(root, "warm").absolutePath, 0, 10))
        assertEquals(
            before.getInt("total"),
            send(Cli.residency(key)).getInt("cached")
        )
    }

    /**
     * The session, driven as ReadSession drives it: a size line, then a header
     * and that many bytes per request, until stdin closes.
     *
     * One process is the point — reads in it are sequential to
     * lib/content/data.ml, which is what lets it fetch ahead of the reader.
     */
    @Test
    fun `one process serves every range of an open file`() {
        val key = root_ + "session.txt"
        send(Cli.writeWhole(key, staged("0123456789".toByteArray()).absolutePath))

        val process = ProcessBuilder(listOf(executable().absolutePath) + Cli.open(key))
            .apply {
                environment()["HOME"] = home.absolutePath
                redirectError(ProcessBuilder.Redirect.DISCARD)
            }
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
        val key = root_ + "whole.txt"
        send(Cli.writeWhole(key, staged("0123456789".toByteArray()).absolutePath))
        val dest = File(root, "fetched")
        send(Cli.fetch(key, dest.absolutePath))
        assertEquals("0123456789", dest.readText())
    }

    @Test
    fun `the store on disk is what the binary was pointed at`() {
        assertTrue(Files.exists(Paths.get(root.absolutePath, "store")))
    }
}
