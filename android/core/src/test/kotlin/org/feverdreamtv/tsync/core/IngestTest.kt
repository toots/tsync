package org.feverdreamtv.tsync.core

import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class IntentFormatTest {
    @Test
    fun readsTheSpecifiedRecord() {
        val intent = Intent.decode(
            """{"target":{"parentRef":"d:9f3a","name":"report.pdf"}, "exclusive":true,
               "base":"1294bbe85c2f380b", "modified":1755347464000, "state":"ready", "future":1}"""
        )
        assertEquals(
            Intent(Target.Child("d:9f3a", "report.pdf"), true, "1294bbe85c2f380b", 1755347464000, IntentState.READY),
            intent,
        )
    }

    @Test
    fun writesExactlyTheSpecifiedFields() {
        val child = JSONObject(Intent(Target.Child("root", "a"), exclusive = true).encode())
        assertEquals(setOf("target", "exclusive", "state"), child.keySet())
        assertEquals(setOf("parentRef", "name"), child.getJSONObject("target").keySet())
        assertEquals("open", child.getString("state"))
        val existing = Intent(Target.Existing("i:1", "a"), false, "b", 5, IntentState.READY)
        val encoded = JSONObject(existing.encode())
        assertEquals(setOf("target", "exclusive", "state", "base", "modified"), encoded.keySet())
        assertEquals(setOf("ref", "name"), encoded.getJSONObject("target").keySet())
        assertEquals(existing, Intent.decode(existing.encode()))
    }

    @Test
    fun anUnknownStateOrABrokenRecordDoesNotDecode() {
        assertNull(Intent.decode("""{"target":{"parentRef":"root","name":"a"},"exclusive":true,"state":"sealed"}"""))
        assertNull(Intent.decode("""{"target":{"name":"a"},"exclusive":true,"state":"open"}"""))
        assertNull(Intent.decode("{"))
    }
}

class IntentStoreTest {
    private val home = Files.createTempDirectory("home").toFile()
    private val store = IntentStore(home)
    private val day = Parameters.STAGING_ORPHAN_AGE_MS

    private fun staged(name: String, intent: Intent?): String {
        store.staging(name).writeText("body")
        intent?.let { store.put(name, it) }
        return name
    }

    @Test
    fun locationsAreTheSpecified() {
        val name = staged(store.newName(1755347464000), Intent(Target.Child("root", "a"), true))
        assertTrue(Regex("1755347464000-[0-9a-f-]{36}").matches(name))
        assertTrue(File(home, "staging/$name").exists())
        assertTrue(File(home, "intents/$name.json").exists())
    }

    @Test
    fun processStartDiscardsOpenAndKeepsReadyAndUnreadable() {
        val open = staged("1-open", Intent(Target.Child("root", "a"), true))
        val ready = staged("2-ready", Intent(Target.Child("root", "b"), true, state = IntentState.READY))
        val odd = staged("3-odd", null)
        File(home, "intents/3-odd.json").writeText("""{"target":{"parentRef":"root","name":"c"},"exclusive":true,"state":"sealed"}""")
        File(home, "intents/4-x.json.tmp").writeText("{")
        store.recover()
        assertFalse(store.staging(open).exists() || store.exists(open))
        assertTrue(store.staging(ready).exists() && store.exists(ready))
        assertTrue(store.staging(odd).exists() && store.exists(odd))
        assertEquals(listOf("2-ready", "3-odd"), store.names())
        assertEquals(listOf("2-ready.json", "3-odd.json"), File(home, "intents").list()!!.sorted())
    }

    @Test
    fun theSweepNeverDeletesAFileAnIntentNames() {
        val now = 10 * day
        staged("${now - 2 * day}-old-orphan", null)
        staged("${now - day / 2}-young-orphan", null)
        val named = staged("${now - 2 * day}-named", Intent(Target.Child("root", "a"), true, state = IntentState.READY))
        val unreadable = staged("${now - 2 * day}-unreadable", null)
        File(home, "intents/$unreadable.json").writeText("garbage")
        staged("no-time-in-name", null)
        assertEquals(1, store.sweep(now))
        assertEquals(
            listOf("${now - day / 2}-young-orphan", named, unreadable, "no-time-in-name").sorted(),
            store.stagingDirectory.list()!!.sorted(),
        )
    }

    @Test
    fun readyIsDurableBeforeItIsReported() {
        val name = staged(store.newName(), Intent(Target.Child("root", "a"), true))
        val ready = store.markReady(name, store.read(name)!!)
        assertEquals(IntentState.READY, ready.state)
        assertEquals(IntentState.READY, IntentStore(home).read(name)!!.state)
    }
}

class IngestTest {
    private val home = Files.createTempDirectory("home").toFile()
    private val fake = FakeCore()
    private val ingest = Ingest(Client(fake), IntentStore(home))

    private fun stage(target: Target, exclusive: Boolean = true, body: String = "body", ready: Boolean = true, base: String? = null, modified: Long? = null): String {
        val name = ingest.stage(target, exclusive, base, modified)
        ingest.staging(name).writeText(body)
        if (ready) ingest.markReady(name)
        return name
    }

    private fun restarted(): Ingest {
        val store = IntentStore(home)
        store.recover()
        return Ingest(Client(fake), store)
    }

    @Test
    fun commitAdoptsTheStagingFileAndKeepsItsMtime() {
        val name = stage(Target.Child("root", "photo.jpg"), modified = 1_755_347_464_000)
        val committed = ingest.commit(name)
        assertFalse(committed.rerouted)
        assertEquals(1_755_347_464_000, committed.item.mtimeMillis)
        assertFalse(ingest.staging(name).exists())
        assertFalse(ingest.intents.exists(name))
        assertEquals("body", String(fake.child("root", "photo.jpg")!!.content))
    }

    @Test
    fun anExclusiveSaveNeverReplacesAndTakesTheNextName() {
        fake.pageLimit = 1
        fake.add("root", "a.txt", content = "theirs")
        fake.add("root", "a (1).txt", content = "theirs too")
        val committed = ingest.commit(stage(Target.Child("root", "a.txt"), body = "mine"))
        assertEquals("a (2).txt", committed.item.name)
        assertEquals("theirs", String(fake.child("root", "a.txt")!!.content))
        assertEquals("theirs too", String(fake.child("root", "a (1).txt")!!.content))
        assertTrue(fake.requests.all { it.getString("action") == "write" && it.getBoolean("exclusive") })
    }

    @Test
    fun aCommitThatHappenedBeforeAKillIsNotSavedTwice() {
        val modified = 1_755_347_464_000
        ingest.commit(stage(Target.Child("root", "photo.jpg"), modified = modified))
        val again = ingest.commit(stage(Target.Child("root", "photo.jpg"), modified = modified))
        assertEquals("photo.jpg", again.item.name)
        assertNull(fake.child("root", "photo (1).jpg"))
        val other = ingest.commit(stage(Target.Child("root", "photo.jpg"), body = "another photo", modified = modified))
        assertEquals("photo (1).jpg", other.item.name)
    }

    @Test
    fun aFailedCommitKeepsAReadySaveAndDropsAnOpenOne() {
        fake.refuse = { "internal" to "disk on fire" }
        val ready = stage(Target.Child("root", "a"))
        val open = stage(Target.Child("root", "b"), ready = false)
        val failure = assertFailsWith<CoreException> { ingest.commit(ready) }
        assertEquals(Code.INTERNAL to "disk on fire", failure.code to failure.message)
        assertFailsWith<CoreException> { ingest.commit(open) }
        assertTrue(ingest.staging(ready).exists() && ingest.intents.exists(ready))
        assertFalse(ingest.staging(open).exists() || ingest.intents.exists(open))
        assertEquals(listOf(ready), ingest.pending().map { it.staging })
        fake.refuse = { null }
        assertNotNull(ingest.retry(ready))
        assertEquals(emptyList(), ingest.pending())
    }

    @Test
    fun aVanishedTargetGoesToTheRootUnderItsNameWithoutReplacing() {
        fake.add("root", "report.pdf", content = "theirs")
        val gone = stage(Target.Child("d:0404", "report.pdf"))
        val edited = stage(Target.Existing("i:" + "0".repeat(32), "notes.txt"), exclusive = false, base = "abc")
        val first = ingest.commit(gone)
        val second = ingest.commit(edited)
        assertTrue(first.rerouted && second.rerouted)
        assertEquals("report (1).pdf", first.item.name)
        assertEquals("root", second.item.parentRef)
        assertEquals("notes.txt", second.item.name)
        assertEquals("theirs", String(fake.child("root", "report.pdf")!!.content))
    }

    @Test
    fun anEditIsSavedToTheDocumentRenamedMeanwhile() {
        val document = fake.add("root", "draft.txt", content = "v1")
        val name = stage(Target.Existing(document.ref, "draft.txt"), exclusive = false, body = "v2", base = "abc")
        fake.requests.clear()
        document.name = "final.txt"
        val committed = ingest.commit(name)
        assertEquals(document.ref, committed.item.ref)
        assertEquals("v2", String(fake.child("root", "final.txt")!!.content))
        assertEquals(listOf("final.txt"), fake.names("root"))
        assertEquals("abc", fake.requests.single().getString("base"))
    }

    @Test
    fun aProcessKilledAtEveryStepLosesNoReportedSaveAndPublishesNoPartialBody() {
        // Killed after the intent, before the body is complete: nothing was reported.
        val interrupted = ingest.stage(Target.Child("root", "partial.bin"), true)
        ingest.staging(interrupted).writeText("half")
        // Killed after ready, before commit: success was reported.
        val reported = stage(Target.Child("root", "whole.bin"), body = "whole")
        // Killed after the core adopted the body, before the intent was deleted.
        val adopted = stage(Target.Child("root", "adopted.bin"), body = "adopted")
        fake.add("root", "adopted.bin", content = "adopted")
        ingest.staging(adopted).delete()

        val next = restarted()
        val outcomes = mutableListOf<Pair<String, Boolean>>()
        next.resumeReady { save, result -> outcomes += save.staging to result.isSuccess }
        assertFalse(next.intents.exists(interrupted) || next.staging(interrupted).exists())
        assertNull(fake.child("root", "partial.bin"))
        assertEquals("whole", String(fake.child("root", "whole.bin")!!.content))
        assertEquals(listOf(reported to true), outcomes)
        assertFalse(next.intents.exists(adopted))
        assertEquals("adopted", String(fake.child("root", "adopted.bin")!!.content))
        assertEquals(listOf("adopted.bin", "whole.bin"), fake.names("root"))
    }

    @Test
    fun resumeLeavesTheSavesOfRunningFlowsAlone() {
        val running = stage(Target.Child("root", "a"))
        var resumed = 0
        ingest.resumeReady { _, _ -> resumed++ }
        assertEquals(0, resumed)
        assertNull(ingest.retry(running))
        ingest.commit(running)
        assertEquals(listOf("a"), fake.names("root"))
    }

    @Test
    fun anUnreadableRecordIsReportedAndKept() {
        File(home, "staging/5-odd").writeText("body")
        File(home, "intents/5-odd.json").writeText("""{"state":"later"}""")
        val next = restarted()
        next.resumeReady { _, _ -> error("must not commit") }
        assertEquals(listOf(PendingSave("5-odd", null)), next.pending())
        assertTrue(File(home, "staging/5-odd").exists())
    }
}
