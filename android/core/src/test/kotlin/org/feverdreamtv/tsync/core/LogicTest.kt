package org.feverdreamtv.tsync.core

import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WireShapeTest {
    private fun core(reply: String) = object : Core by FakeCore() {
        override fun request(json: String) = reply
    }

    @Test
    fun requestsCarryTheSpecifiedFields() {
        assertEquals(setOf("action", "ref"), Requests.stat("i:1").keySet())
        assertEquals(setOf("action", "parentRef", "name"), Requests.statChild("root", "a").keySet())
        val listing = Requests.listDir("root", "m", 10, Pull.NOW)
        assertEquals("list_dir", listing.getString("action"))
        assertEquals("now", listing.getString("pull"))
        assertEquals("m", listing.getString("after"))
        assertFalse(Requests.listDir("root", null, null, Pull.DEFAULT).has("pull"))
        val write = Requests.writeChild("d:1", "a.txt", "/s/1", "abc", true)
        assertTrue(write.getBoolean("await") && write.getBoolean("exclusive"))
        assertEquals("abc", write.getString("base"))
        assertFalse(Requests.writeRef("i:1", "/s/1", null).has("base"))
        assertTrue(Requests.rename("i:1", "root", "b").getBoolean("noreplace"))
        assertEquals("off", Requests.pause(false).getString("arg"))
    }

    @Test
    fun rowIsReadFromItsFieldsNotItsReference() {
        val row = """{"ok":true,"ref":"i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384","parentRef":"d:9f3a","name":"big.txt","kind":"file",
            "size":24,"mtime":1400000000.0,"etag":"1294bbe85c2f380b","isUploaded":false,"contentId":"1294bbe85c2f380b",
            "readOnly":true,"availability":"pinned","pinnedUntil":1755347464}"""
        val item = Client(core(row)).stat("i:6c1e0b9a2f4d47e8a3b5c7d9e1f20384")
        assertEquals(Kind.FILE, item.kind)
        assertEquals(24, item.size)
        assertEquals(1_400_000_000_000, item.mtimeMillis)
        assertFalse(item.isUploaded)
        assertTrue(item.readOnly)
        assertEquals(Availability.PINNED, item.availability)
        assertEquals(1755347464, item.pinnedUntil)
        val folder = Item.of(JSONObject("""{"ref":"d:1","parentRef":"root","name":"i:looks-like-a-file","kind":"dir"}"""))
        assertTrue(folder.isDir)
        assertNull(folder.contentId)
    }

    @Test
    fun everyFailureKeepsItsCode() {
        fun code(reply: String) = assertFailsWith<CoreException> { Client(core(reply)).stat("root") }.code
        assertEquals(Code.NOT_FOUND, code("""{"ok":false,"code":"not_found","error":"gone"}"""))
        assertEquals(Code.UNREACHABLE, code("""{"ok":false,"code":"unreachable","error":"silent"}"""))
        assertEquals(Code.INTERNAL, code("""{"ok":false,"code":"brand_new","error":"?"}"""))
        assertEquals(Code.INTERNAL, code("""{"ok":false,"error":"no code"}"""))
        assertEquals(Code.INTERNAL, code("not json"))
        val taken = assertFailsWith<CoreException> {
            Client(core("""{"ok":false,"code":"exists","error":"taken","item":{"ref":"i:1","name":"a","kind":"file"}}""")).stat("root")
        }
        assertEquals("taken", taken.message)
        assertEquals("i:1", taken.occupant?.ref)
    }

    @Test
    fun aFailedListingIsNeverAnEmptyFolder() {
        val fake = FakeCore()
        fake.refuse = { ("unreachable" to "Cannot reach the server").takeIf { _ -> it.getString("action") == "list_dir" } }
        assertEquals(Code.UNREACHABLE, assertFailsWith<CoreException> { Client(fake).listAll("root") }.code)
    }

    @Test
    fun aListingFollowsNextToTheEnd() {
        val fake = FakeCore()
        fake.pageLimit = 2
        repeat(5) { fake.add("root", "f$it") }
        val listing = Client(fake).listAll("root")
        assertEquals(listOf("f0", "f1", "f2", "f3", "f4"), listing.items.map { it.name })
        assertEquals(3, fake.requests.size)
        assertFalse(fake.requests[1].has("pull"))
    }
}

class NamingTest {
    @Test
    fun sanitising() {
        assertEquals("a_b_c", Naming.sanitizeLeaf("a/b\\c"))
        assertEquals("x_y", Naming.sanitizeLeaf("x\u0007y"))
        assertEquals("name", Naming.sanitizeLeaf("  \u00a0name. . "))
        assertEquals("unnamed", Naming.sanitizeLeaf(" .."))
        assertEquals("unnamed", Naming.sanitizeLeaf(""))
        assertEquals(".hidden", Naming.sanitizeLeaf(".hidden"))
    }

    @Test
    fun numbering() {
        assertEquals("report.pdf", Naming.numbered("report.pdf", 0))
        assertEquals("report (1).pdf", Naming.numbered("report.pdf", 1))
        assertEquals("a.tar (2).gz", Naming.numbered("a.tar.gz", 2))
        assertEquals(".profile (1)", Naming.numbered(".profile", 1))
        assertEquals("notes (3)", Naming.numbered("notes", 3))
        assertEquals(Parameters.MAX_NAME_ATTEMPTS + 1, Naming.candidates("a").count())
    }

    @Test
    fun cameraNames() {
        val capture = java.time.Instant.parse("2026-08-16T12:31:04Z").toEpochMilli()
        val paris = java.time.ZoneId.of("Europe/Paris")
        assertEquals("Camera Uploads/2026/2026-08-16 14.31.04.jpg", Naming.cameraTarget(capture, paris, "IMG_1234.JPG"))
        assertEquals("", Naming.cameraExtension("noext"))
        assertEquals("", Naming.cameraExtension(".hidden"))
        assertEquals("", Naming.cameraExtension("trailing."))
        assertEquals("", Naming.cameraExtension("a.j pg"))
        assertEquals(".mp4", Naming.cameraExtension("a.b.MP4"))
        val target = "Camera Uploads/2026/2026-08-16 14.31.04.jpg"
        assertEquals(target, Naming.unnumbered(Naming.numbered(target, 7)))
        assertEquals(target, Naming.unnumbered(target))
        assertEquals("Camera Uploads/2026/x", Naming.unnumbered("Camera Uploads/2026/x (2)"))
    }
}

class KeepAliveTest {
    @Test
    fun reportsOnlyTheEdges() {
        val counter = KeepAliveCounter()
        assertFalse(counter.release(KeepAliveCounter.Work.SAVE))
        assertTrue(counter.retain(KeepAliveCounter.Work.OPEN_FILE))
        assertFalse(counter.retain(KeepAliveCounter.Work.SAVE))
        assertFalse(counter.release(KeepAliveCounter.Work.OPEN_FILE))
        assertFalse(counter.release(KeepAliveCounter.Work.OPEN_FILE))
        assertEquals(KeepAliveCounter.Held(0, 1), counter.held())
        assertTrue(counter.release(KeepAliveCounter.Work.SAVE))
        assertFalse(counter.release(KeepAliveCounter.Work.SAVE))
        assertEquals(0, counter.held().total)
    }
}

class OfflineLatchTest {
    @Test
    fun onlyRecoveryOrAFreshListingClears() {
        val latch = OfflineLatch()
        latch.failed(CoreException(Code.INTERNAL, "x"))
        assertFalse(latch.offline)
        latch.failed(CoreException(Code.UNREACHABLE, "x"))
        assertTrue(latch.offline)
        latch.recovered()
        assertFalse(latch.offline)
        latch.listed(Listing(emptyList(), null, 1, outdated = true))
        assertTrue(latch.offline)
        latch.failed(CoreException(Code.NOT_FOUND, "x"))
        assertTrue(latch.offline)
        latch.listed(Listing(emptyList(), null, 1, outdated = false))
        assertFalse(latch.offline)
    }
}

class TreeTest {
    private val fake = FakeCore()
    private val client = Client(fake)

    @Test
    fun isChildReachesEveryDescendantAndNothingElse() {
        val a = fake.add("root", "a", dir = true)
        val b = fake.add(a.ref, "b", dir = true)
        val file = fake.add(b.ref, "f.txt")
        val other = fake.add("root", "other", dir = true)
        assertTrue(Tree.isChild(client, "root", file.ref))
        assertTrue(Tree.isChild(client, a.ref, file.ref))
        assertTrue(Tree.isChild(client, a.ref, b.ref))
        assertFalse(Tree.isChild(client, other.ref, file.ref))
        assertFalse(Tree.isChild(client, a.ref, a.ref))
        assertFalse(Tree.isChild(client, a.ref, "root"))
        assertFalse(Tree.isChild(client, a.ref, "i:" + "f".repeat(32)))
        assertTrue(Tree.isWithin(client, a.ref, a.ref))
        assertTrue(Tree.isWithin(client, a.ref, b.ref))
        assertFalse(Tree.isWithin(client, b.ref, a.ref))
    }

    @Test
    fun foldersAreResolvedByMkdirAndCached() {
        val cache = HashMap<String, String>()
        val folders = Folders(client, object : FolderCache {
            override fun get(path: String) = cache[path]
            override fun put(path: String, ref: String) { cache[path] = ref }
            override fun remove(path: String) { cache.remove(path) }
        })
        val year = folders.folderFor("Camera Uploads/2026")
        assertEquals(listOf("Camera Uploads"), fake.names("root"))
        assertEquals(year, folders.folderFor("Camera Uploads/2026"))
        assertEquals(2, fake.requests.size)
        fake.nodes.remove(year)
        folders.forget("Camera Uploads/2026")
        val again = folders.folderFor("Camera Uploads/2026")
        assertTrue(again != year && fake.nodes.containsKey(again))
    }
}

class TrustBundleTest {
    @Test
    fun takesCompleteBlocksAndReplacesOnlyOnChange() {
        val dir = Files.createTempDirectory("trust").toFile()
        val updatable = File(dir, "apex").apply { mkdirs() }
        val system = File(dir, "system").apply { mkdirs() }
        val block = "-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----"
        File(system, "a.0").writeText("$block\nCertificate:\n  Data: text dump\n")
        File(system, "b.0").writeText("-----BEGIN CERTIFICATE-----\nQUJD\n")
        val bundle = File(dir, "ca-bundle.pem")
        assertFalse(TrustBundle.refresh(bundle, listOf(File(dir, "missing"))))
        assertTrue(TrustBundle.refresh(bundle, listOf(updatable, system)))
        assertEquals("$block\n", bundle.readText())
        val stamp = bundle.lastModified()
        bundle.setLastModified(stamp - 5000)
        TrustBundle.refresh(bundle, listOf(updatable, system))
        assertEquals(stamp - 5000, bundle.lastModified())
        File(updatable, "c.0").writeText(block.replace("QUJD", "REVG"))
        TrustBundle.refresh(bundle, listOf(updatable, system))
        assertTrue("REVG" in bundle.readText() && "QUJD" !in bundle.readText())
        assertTrue(TrustBundle.refresh(bundle, listOf(File(dir, "missing"))))
        assertTrue("REVG" in bundle.readText())
    }
}
