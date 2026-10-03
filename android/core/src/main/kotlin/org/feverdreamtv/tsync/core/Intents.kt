package org.feverdreamtv.tsync.core

import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Where a staged body goes (app §8.2). `name` of an existing file is only the fallback's. */
sealed interface Target {
    val name: String

    data class Child(val parentRef: String, override val name: String) : Target
    data class Existing(val ref: String, override val name: String) : Target
}

enum class IntentState(val wire: String) { OPEN("open"), READY("ready") }

data class Intent(
    val target: Target,
    val exclusive: Boolean,
    val base: String? = null,
    val modified: Long? = null,
    val state: IntentState = IntentState.OPEN,
) {
    fun encode(): String {
        val where = JSONObject().put("name", target.name)
        when (target) {
            is Target.Child -> where.put("parentRef", target.parentRef)
            is Target.Existing -> where.put("ref", target.ref)
        }
        val record = JSONObject().put("target", where).put("exclusive", exclusive).put("state", state.wire)
        base?.let { record.put("base", it) }
        modified?.let { record.put("modified", it) }
        return record.toString()
    }

    companion object {
        /** @return null for a record that does not decode or whose state is neither of the two. */
        fun decode(text: String): Intent? = try {
            val record = JSONObject(text)
            val where = record.getJSONObject("target")
            val name = where.getString("name")
            val target = when {
                where.has("ref") -> Target.Existing(where.getString("ref"), name)
                else -> Target.Child(where.getString("parentRef"), name)
            }
            val state = IntentState.entries.firstOrNull { it.wire == record.getString("state") }
            state?.let {
                Intent(
                    target = target,
                    exclusive = record.getBoolean("exclusive"),
                    base = text(record, "base"),
                    modified = if (record.has("modified") && !record.isNull("modified")) record.getLong("modified") else null,
                    state = it,
                )
            }
        } catch (e: JSONException) {
            null
        }
    }
}

/** The staging directory and the durable intent of each staging file (app §3, §8.2). */
class IntentStore(home: File) {
    val stagingDirectory = File(home, "staging")
    private val intentsDirectory = File(home, "intents")

    init {
        Durable.privateDirectory(stagingDirectory)
        Durable.privateDirectory(intentsDirectory)
    }

    /** The name carries its creation time: commit rewrites the file's mtime (app §3). */
    fun newName(now: Long = System.currentTimeMillis()): String = "$now-${UUID.randomUUID()}"

    fun staging(name: String): File = File(stagingDirectory, name)

    private fun record(name: String): File = File(intentsDirectory, "$name$RECORD_SUFFIX")

    fun put(name: String, intent: Intent) = Durable.write(record(name), intent.encode().toByteArray())

    fun exists(name: String): Boolean = record(name).exists()

    fun read(name: String): Intent? = try {
        Intent.decode(record(name).readText())
    } catch (e: java.io.IOException) {
        null
    }

    /** The staging file is fsynced before the record says ready (app §8.2). */
    fun markReady(name: String, intent: Intent): Intent {
        Durable.fsync(staging(name))
        val ready = intent.copy(state = IntentState.READY)
        put(name, ready)
        return ready
    }

    /** After adoption: the core owns the body. */
    fun forget(name: String) {
        Durable.delete(record(name))
        staging(name).delete()
    }

    fun discard(name: String) {
        staging(name).delete()
        Durable.delete(record(name))
    }

    fun names(): List<String> =
        intentsDirectory.list().orEmpty().filter { it.endsWith(RECORD_SUFFIX) }.map { it.removeSuffix(RECORD_SUFFIX) }.sorted()

    /**
     * At process start, before any write begins. An open intent is an interrupted write; a ready
     * one whose staging file is gone was adopted by the core just before the process died.
     */
    fun recover() {
        intentsDirectory.listFiles().orEmpty().filter { it.name.endsWith(Durable.TEMP_SUFFIX) }.forEach { it.delete() }
        for (name in names()) {
            val intent = read(name) ?: continue
            if (intent.state == IntentState.OPEN || !staging(name).exists()) discard(name)
        }
    }

    /** Deletes only staging files no intent names and whose name says they are old enough. */
    fun sweep(now: Long = System.currentTimeMillis()): Int {
        val orphans = stagingDirectory.list().orEmpty().filter { name ->
            val created = name.substringBefore('-').toLongOrNull()
            created != null && now - created > Parameters.STAGING_ORPHAN_AGE_MS && !exists(name)
        }
        orphans.forEach { staging(it).delete() }
        return orphans.size
    }

    private companion object {
        const val RECORD_SUFFIX = ".json"
    }
}
