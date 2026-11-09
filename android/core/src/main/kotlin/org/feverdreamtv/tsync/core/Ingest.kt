package org.feverdreamtv.tsync.core

import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** A staged body [domain] adopted. `rerouted` says its target was gone and it went to the root. */
data class Committed(val item: Item, val rerouted: Boolean, val domain: String)

/** A save that did not reach the domain and is still on the phone. */
data class PendingSave(val staging: String, val intent: Intent?)

/**
 * The only way bytes enter a domain from the app (app §8). [firstDomain] names the domain of an
 * intent that names none; [client] is a domain's, booted.
 */
class Ingest(val intents: IntentStore, private val firstDomain: () -> String?, private val client: (String) -> Client) {
    // Staging names a flow of this process is working on: resume and retry leave them alone.
    private val claimed = ConcurrentHashMap.newKeySet<String>()

    /** Writes the open intent for a new staging name, before the file is handed to anyone. */
    fun stage(domain: String, target: Target, exclusive: Boolean, base: String? = null, modified: Long? = null, created: Long? = null): String {
        val name = intents.newName()
        claimed += name
        intents.put(name, Intent(target, exclusive, base, modified, domain = domain, created = created))
        return name
    }

    fun staging(name: String): File = intents.staging(name)

    fun domainOf(intent: Intent): String? = intent.domain ?: firstDomain()

    fun update(name: String, change: (Intent) -> Intent): Intent {
        val intent = change(read(name))
        intents.put(name, intent)
        return intent
    }

    fun markReady(name: String): Intent = intents.markReady(name, read(name))

    fun abandon(name: String) {
        intents.discard(name)
        claimed -= name
    }

    /**
     * app §8.1. On failure the staging file stays while its intent is ready, else both go.
     * @param candidates the names an exclusive creation tries in turn on `exists`
     * @param reroute whether a vanished target falls back to the root (app §8.2)
     */
    fun commit(
        name: String,
        candidates: (String) -> Sequence<String> = Naming::candidates,
        reroute: Boolean = true,
    ): Committed {
        val intent = read(name)
        try {
            val staging = intents.staging(name)
            Durable.fsync(staging)
            intent.modified?.let { staging.setLastModified(it) }
            val committed = write(intent, staging.path, candidates, reroute)
            intents.forget(name)
            return committed
        } catch (e: Exception) {
            if (intent.state != IntentState.READY) intents.discard(name)
            throw if (e is CoreException) e else CoreException(Code.INTERNAL, e.message ?: e.toString())
        } finally {
            claimed -= name
        }
    }

    private fun write(intent: Intent, staging: String, candidates: (String) -> Sequence<String>, reroute: Boolean): Committed {
        val domain = domainOf(intent) ?: throw CoreException(Code.INTERNAL, "no domain is configured")
        val client = client(domain)
        return try {
            Committed(client.writeTo(intent.target, intent, staging, candidates), rerouted = false, domain)
        } catch (e: CoreException) {
            if (e.code != Code.NOT_FOUND || !reroute) throw e
            val fallback = Target.Child(Parameters.ROOT, Naming.sanitizeLeaf(intent.target.name))
            Committed(client.writeTo(fallback, intent.copy(exclusive = true), staging, candidates), rerouted = true, domain)
        }
    }

    private fun Client.writeTo(target: Target, intent: Intent, staging: String, candidates: (String) -> Sequence<String>): Item {
        val createdNs = intent.created?.let { it * 1_000_000 }
        return when (target) {
            is Target.Existing -> writeRef(target.ref, staging, intent.base, createdNs)
            is Target.Child ->
                if (!intent.exclusive) writeChild(target.parentRef, target.name, staging, intent.base, false, createdNs)
                else firstFree(candidates(target.name)) { name ->
                    try {
                        writeChild(target.parentRef, name, staging, intent.base, true, createdNs)
                    } catch (e: CoreException) {
                        adoptedBefore(e, intent, File(staging)) ?: throw e
                    }
                }
        }
    }

    /**
     * app §8.1: the name is held by this very body, adopted by a process that died before it
     * recorded so. Numbering past it would save the file twice.
     */
    private fun adoptedBefore(refusal: CoreException, intent: Intent, staging: File): Item? {
        val occupant = refusal.occupant ?: return null
        // A photo's capture time is its creation time, which an edit never moves.
        val (held, wanted) = intent.created?.let { occupant.createdMillis to it }
            ?: intent.modified?.let { occupant.mtimeMillis to it } ?: return null
        val same = refusal.code == Code.EXISTS && !occupant.isDir && occupant.size == staging.length() &&
            Math.abs(held - wanted) < 1000
        if (!same) return null
        staging.delete()
        return occupant
    }

    /** Commits what earlier processes left ready for [domain] (app §8.2), reporting each outcome. */
    fun resumeReady(domain: String, report: (PendingSave, Result<Committed>) -> Unit) {
        for (save in pending()) {
            if (save.intent == null || domainOf(save.intent) != domain || !claimed.add(save.staging)) continue
            report(save, runCatching { commit(save.staging) })
        }
    }

    /** Commits one failed save again. @return null when a flow of this process already holds it. */
    fun retry(name: String): Committed? = if (claimed.add(name)) commit(name) else null

    /** Saves no flow is working on: failed ones, and records that cannot be read (intent null). */
    fun pending(): List<PendingSave> =
        intents.names().filter { it !in claimed }.map { PendingSave(it, intents.read(it)) }
            .filter { it.intent?.state != IntentState.OPEN }

    private fun read(name: String): Intent =
        intents.read(name) ?: throw CoreException(Code.INTERNAL, "the save record of $name cannot be read")

    companion object {
        /** app §5: on `exists` the caller picks the next name; the owner checks and creates in one step. */
        fun <T> firstFree(names: Sequence<String>, attempt: (String) -> T): T {
            var taken: CoreException? = null
            for (name in names) {
                try {
                    return attempt(name)
                } catch (e: CoreException) {
                    if (e.code != Code.EXISTS) throw e
                    taken = e
                }
            }
            throw taken ?: CoreException(Code.EXISTS, "no free name")
        }
    }
}
