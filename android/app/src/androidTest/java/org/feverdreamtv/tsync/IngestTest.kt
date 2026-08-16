package org.feverdreamtv.tsync

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Ingestion over a real LocalSocket, which is the one part of the wire a JVM
 * test cannot reach.
 */
@RunWith(AndroidJUnit4::class)
class IngestTest {

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var daemon: FakeDaemon
    private val root = Keys.root("photos")

    @Before
    fun start() {
        daemon = FakeDaemon(File(context.cacheDir, "fake/tsync.sock"))
    }

    @After
    fun stop() = daemon.close()

    @Test
    fun commitSendsWriteWithTheStagingPath() {
        val staging = Ingest.newStaging(context)
        staging.writeText("hello")

        Ingest.commit(daemon.socketFile, root + "shot.jpg", staging)

        val write = daemon.requestsFor("write").single()
        assertEquals(root + "shot.jpg", write.getString("path"))
        assertEquals(staging.absolutePath, write.getString("staging"))
    }

    /** A zero-length staged manifest would otherwise be published as the file. */
    @Test
    fun commitNeverSendsCreate() {
        val staging = Ingest.newStaging(context)
        staging.writeText("hello")
        Ingest.commit(daemon.socketFile, root + "shot.jpg", staging)
        assertFalse("create" in daemon.actions())
    }

    @Test
    fun commitCarriesTheCaptureTime() {
        val staging = Ingest.newStaging(context)
        staging.writeText("hello")
        val captured = 1_400_000_000_000L

        Ingest.commit(daemon.socketFile, root + "shot.jpg", staging, modified = captured)

        assertEquals(captured / 1000, staging.lastModified() / 1000)
    }

    @Test
    fun aFailedWriteRemovesTheStagedBody() {
        daemon.answer = { daemon.notFound() }
        val staging = Ingest.newStaging(context)
        staging.writeText("hello")

        runCatching { Ingest.commit(daemon.socketFile, root + "shot.jpg", staging) }

        assertFalse("a body the daemon refused must not linger", staging.exists())
    }

    @Test
    fun ensureDirsCreatesEveryMissingAncestorOutermostFirst() {
        daemon.answer = { request ->
            if (request.optString("action") == "stat") daemon.notFound()
            else org.json.JSONObject().put("ok", true)
        }

        Ingest.ensureDirs(
            daemon.socketFile, root, root + "Camera Uploads/2026/shot.jpg", mutableSetOf()
        )

        assertEquals(
            listOf(root + "Camera Uploads/", root + "Camera Uploads/2026/"),
            daemon.requestsFor("mkdir").map { it.getString("path") }
        )
    }

    @Test
    fun ensureDirsLeavesFoldersThatAlreadyExist() {
        Ingest.ensureDirs(
            daemon.socketFile, root, root + "Camera Uploads/2026/shot.jpg", mutableSetOf()
        )
        assertTrue(daemon.requestsFor("mkdir").isEmpty())
    }

    /** The folder memo is what keeps a sweep from a stat per photo, each of
     *  which costs the daemon a lookup. */
    @Test
    fun ensureDirsAsksOnceForFoldersItHasSeen() {
        val known = mutableSetOf<String>()
        repeat(3) {
            Ingest.ensureDirs(
                daemon.socketFile, root, root + "Camera Uploads/2026/shot$it.jpg", known
            )
        }
        assertEquals(2, daemon.requestsFor("stat").size)
    }

    @Test
    fun orphanedStagedBodiesAreSweptByAge() {
        val old = Ingest.newStaging(context)
        old.writeText("x")
        val renamed = File(old.parentFile, "1000-${old.name.substringAfter('-')}")
        old.renameTo(renamed)
        val fresh = Ingest.newStaging(context)
        fresh.writeText("x")

        Ingest.sweepOrphans(context, age = 60_000)

        assertFalse(renamed.exists())
        assertTrue("a body staged moments ago is still owed", fresh.exists())
    }
}
