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
import java.net.StandardProtocolFamily
import java.net.UnixDomainSocketAddress
import java.nio.channels.Channels
import java.nio.channels.SocketChannel
import java.nio.file.Files
import java.nio.file.Paths
import java.util.UUID
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * The protocol, against a real daemon.
 *
 * The two sides agree on storage keys, action names and field names by having
 * the same strings written out in OCaml and in Kotlin, which is not a mechanism
 * — so the daemon is started for real, from the binary in this repo, against a
 * local store in a temporary directory. No network and no device.
 *
 * The daemon here is the host build, not the cross-built one that ships: what is
 * under test is the wire, and only [IpcWire] is exercised — the LocalSocket that
 * opens it on a phone cannot run off one.
 */
class DaemonProtocolTest {

    private lateinit var root: File
    private lateinit var home: File
    private lateinit var socket: File
    private var daemon: Process? = null

    /** Daemon threads, so one stuck on a read cannot keep the test JVM alive. */
    private val calls: ExecutorService = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "ipc-call").apply { isDaemon = true }
    }

    private val domain = "iface"

    companion object {
        private const val REPLY_TIMEOUT_SECONDS = 20L
        private const val STARTUP_TIMEOUT_SECONDS = 20L

        /** Set by CI, where a missing daemon is a broken job rather than a
         *  developer who has not run dune yet. */
        private val REQUIRED = System.getenv("CI") == "true"

        private const val BUILT = "_build/default/bin/tsync.exe"

        private fun executable(): File {
            System.getenv("TSYNC_DAEMON")?.let { return File(it) }
            System.getProperty("tsync.repo")?.let { repository ->
                val candidate = File(repository, BUILT)
                if (candidate.isFile) return candidate
            }
            var directory: File? = File(System.getProperty("user.dir"))
            while (directory != null) {
                val candidate = File(directory, BUILT)
                if (candidate.isFile) return candidate
                directory = directory.parentFile
            }
            return File(BUILT)
        }
    }

    @Before
    fun startDaemon() {
        val binary = executable()
        if (REQUIRED) {
            assertTrue(
                "no daemon at $binary — the job must build bin/tsync.exe first",
                binary.canExecute()
            )
        } else {
            assumeTrue(
                "no daemon binary; run `dune build bin/tsync.exe` first",
                binary.canExecute()
            )
        }

        // Short on purpose: a unix socket path is capped near 108 bytes and the
        // daemon puts its socket several directories below HOME.
        root = File("/tmp/ts-" + UUID.randomUUID().toString().take(8))
        home = File(root, "h")
        val store = File(root, "store")
        val config = DaemonPaths.config(home)
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
                            // Serves the IPC socket this test drives, with no
                            // mount and no extension to talk to.
                            .put("frontends", JSONArray().put("headless"))
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

        socket = DaemonPaths.socket(home, domain)
        daemon = ProcessBuilder(binary.absolutePath, "start")
            .apply {
                environment()["HOME"] = home.absolutePath
                redirectOutput(ProcessBuilder.Redirect.DISCARD)
                redirectError(ProcessBuilder.Redirect.DISCARD)
            }
            .start()

        awaitReady()
    }

    @After
    fun stopDaemon() {
        calls.shutdownNow()
        daemon?.destroy()
        daemon?.waitFor()
        root.deleteRecursively()
    }

    private fun awaitReady() {
        val deadline = System.currentTimeMillis() + STARTUP_TIMEOUT_SECONDS * 1000
        while (System.currentTimeMillis() < deadline) {
            if (runCatching { send("status", timeoutSeconds = 2) }.isSuccess) return
            Thread.sleep(100)
        }
        throw AssertionError("daemon did not come up within ${STARTUP_TIMEOUT_SECONDS}s")
    }

    // ── The wire under test ──────────────────────────────────────────────────

    /**
     * A unix SocketChannel has no read timeout to set, so the call is bounded
     * from outside: a daemon that accepts and then says nothing has to fail the
     * test rather than stop the suite.
     */
    private fun send(
        action: String,
        fields: Map<String, Any> = emptyMap(),
        timeoutSeconds: Long = REPLY_TIMEOUT_SECONDS
    ): JSONObject {
        val call = calls.submit<JSONObject> {
            SocketChannel.open(StandardProtocolFamily.UNIX).use { channel ->
                channel.connect(UnixDomainSocketAddress.of(Paths.get(socket.absolutePath)))
                IpcWire.wire(
                    Channels.newInputStream(channel),
                    Channels.newOutputStream(channel),
                    IpcWire.request(action, fields)
                )
            }
        }
        return try {
            call.get(timeoutSeconds, TimeUnit.SECONDS)
        } catch (timeout: TimeoutException) {
            call.cancel(true)
            throw AssertionError("no reply to $action within ${timeoutSeconds}s")
        } catch (failed: ExecutionException) {
            throw failed.cause ?: failed
        }
    }

    private val root_ get() = Keys.root(domain)

    private fun staged(contents: ByteArray): File {
        val file = File(root, "staged-" + UUID.randomUUID())
        file.writeBytes(contents)
        return file
    }

    // ── Tests ────────────────────────────────────────────────────────────────

    @Test
    fun `a fresh domain lists nothing`() {
        assertEquals(0, send("list_dir", mapOf("path" to root_)).getJSONArray("items").length())
    }

    /**
     * The reason camera backup creates its date folders rather than letting the
     * upload mint their ids: it does, but writes no Mkdir journal entry, so the
     * folder cannot be listed and the file names the root as its parent.
     */
    @Test
    fun `a write into an uncreated folder leaves it unlistable`() {
        val key = root_ + "Camera Uploads/2026/shot.jpg"
        send("write", mapOf("path" to key, "staging" to staged("hello".toByteArray()).absolutePath))

        val listed = runCatching { send("list_dir", mapOf("path" to root_ + "Camera Uploads/")) }
        assertTrue("listing an unmade folder should fail", listed.isFailure)
    }

    @Test
    fun `mkdir then write puts the file in the folder with the right size and parent`() {
        val folder = root_ + "Camera Uploads/"
        val year = folder + "2026/"
        val key = year + "shot.jpg"
        send("mkdir", mapOf("path" to folder))
        send("mkdir", mapOf("path" to year))
        send("write", mapOf("path" to key, "staging" to staged("hello".toByteArray()).absolutePath))

        val stat = send("stat", mapOf("path" to key))
        assertEquals(5, stat.getInt("size"))
        assertEquals("shot.jpg", stat.getString("name"))

        val parent = send("stat", mapOf("path" to year))
        assertEquals(parent.getString("ref"), stat.getString("parentRef"))

        val items = send("list_dir", mapOf("path" to year)).getJSONArray("items")
        assertEquals(1, items.length())
        assertEquals("shot.jpg", items.getJSONObject(0).getString("name"))
    }

    /** The daemon adopts the staged file by rename, so deleting it afterwards
     *  would delete the content it just took over. */
    @Test
    fun `write consumes the staging file`() {
        val key = root_ + "adopted.txt"
        val staging = staged("hello".toByteArray())
        send("write", mapOf("path" to key, "staging" to staging.absolutePath))
        assertFalse("the daemon should have renamed it away", staging.exists())
    }

    /** Capture time reaches the manifest only through the staged file's own
     *  modification time. */
    @Test
    fun `the staged file's modification time becomes the file's`() {
        val key = root_ + "dated.txt"
        val staging = staged("hello".toByteArray())
        val captured = 1_400_000_000_000L
        staging.setLastModified(captured)
        send("write", mapOf("path" to key, "staging" to staging.absolutePath))

        val mtime = send("stat", mapOf("path" to key)).getDouble("mtime")
        assertEquals(captured / 1000.0, mtime, 2.0)
    }

    @Test
    fun `pause round-trips`() {
        send("pause", mapOf("arg" to "on"))
        assertTrue(send("status").getBoolean("paused"))
        send("pause", mapOf("arg" to "off"))
        assertFalse(send("status").getBoolean("paused"))
    }

    @Test
    fun `status carries the fields a sweep throttles on`() {
        val status = send("status")
        assertTrue(status.has("pendingUploads"))
        assertTrue(status.has("pendingBytes"))
        assertTrue(status.has("pendingDownloads"))
    }

    @Test
    fun `stat on a missing key fails rather than hanging`() {
        val missing = runCatching { send("stat", mapOf("path" to root_ + "nothing.txt")) }
        assertTrue(missing.isFailure)
        assertTrue(missing.exceptionOrNull() is IpcWire.Error)
    }

    /** create writes a zero-length staged manifest of its own, so sending it
     *  before a write briefly publishes an empty file at the key. */
    @Test
    fun `create alone leaves the key empty`() {
        val key = root_ + "created.txt"
        send("create", mapOf("path" to key))
        assertEquals(0, send("stat", mapOf("path" to key)).getInt("size"))
    }

    @Test
    fun `the root of a domain is addressable`() {
        val stat = send("stat", mapOf("path" to root_))
        assertEquals(domain, stat.getString("name"))
        assertNotEquals("", stat.getString("ref"))
    }

    @Test
    fun `a file written twice keeps the newer content`() {
        val key = root_ + "twice.txt"
        send("write", mapOf("path" to key, "staging" to staged("one".toByteArray()).absolutePath))
        send(
            "write",
            mapOf("path" to key, "staging" to staged("three!".toByteArray()).absolutePath)
        )
        assertEquals(6, send("stat", mapOf("path" to key)).getInt("size"))
    }

    @Test
    fun `the store on disk is what the daemon was pointed at`() {
        assertTrue(Files.exists(Paths.get(root.absolutePath, "store")))
    }
}
