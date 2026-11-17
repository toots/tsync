package org.feverdreamtv.tsync.core

import org.json.JSONArray
import org.json.JSONObject

/** failure-model §7.2. */
enum class Code(val wire: String) {
    NOT_FOUND("not_found"),
    EXISTS("exists"),
    NOT_EMPTY("not_empty"),
    READ_ONLY("read_only"),
    DENIED("denied"),
    INVALID("invalid"),
    UNREACHABLE("unreachable"),
    BUSY("busy"),
    PAUSED("paused"),
    LOCKED("locked"),
    INTERNAL("internal");

    companion object {
        fun of(wire: String?): Code = entries.firstOrNull { it.wire == wire } ?: INTERNAL
    }
}

/** A refused request: the owner's sentence, and the code callers branch on (app §5). */
class CoreException(val code: Code, message: String, val occupant: Item? = null) : Exception(message)

enum class Kind {
    DIR, FILE, SYMLINK;

    companion object {
        fun of(wire: String): Kind = when (wire) {
            "dir" -> DIR
            "symlink" -> SYMLINK
            else -> FILE
        }
    }
}

enum class Availability {
    ONLINE_ONLY, CACHED, PINNED;

    companion object {
        fun of(wire: String?): Availability? = when (wire) {
            "online-only" -> ONLINE_ONLY
            "cached" -> CACHED
            "pinned" -> PINNED
            else -> null
        }
    }
}

/** The item row of 08 §2.3. */
data class Item(
    val ref: String,
    val parentRef: String,
    val name: String,
    val kind: Kind,
    val size: Long,
    /** Nanoseconds since the epoch; 0 for a folder. */
    val mtimeNs: Long,
    val createdNs: Long,
    val etag: String,
    val isUploaded: Boolean,
    val contentId: String?,
    val readOnly: Boolean,
    val availability: Availability?,
    val pinnedUntil: Long?,
) {
    val isDir: Boolean get() = kind == Kind.DIR
    val mtimeMillis: Long get() = mtimeNs / 1_000_000
    val createdMillis: Long get() = createdNs / 1_000_000

    companion object {
        fun of(row: JSONObject): Item = Item(
            ref = row.getString("ref"),
            parentRef = row.optString("parentRef", ""),
            name = row.optString("name", ""),
            kind = Kind.of(row.optString("kind", "file")),
            size = row.optLong("size", 0),
            mtimeNs = row.optLong("mtimeNs", 0),
            createdNs = row.optLong("createdNs", 0),
            etag = row.optString("etag", ""),
            isUploaded = row.optBoolean("isUploaded", true),
            contentId = text(row, "contentId"),
            readOnly = row.optBoolean("readOnly", false),
            availability = Availability.of(text(row, "availability")),
            pinnedUntil = if (row.has("pinnedUntil") && !row.isNull("pinnedUntil")) row.optLong("pinnedUntil") else null,
        )
    }
}

data class Listing(val items: List<Item>, val next: String?, val pulledAt: Long?, val outdated: Boolean)

data class Counts(val done: Int, val failed: Int)

data class ShareLink(val url: String, val expires: Long)

data class Upload(val name: String, val size: Long?, val bytes: Long = 0, val rate: Double = 0.0)

data class Download(val name: String, val bytes: Long, val size: Long, val rate: Double)

data class Status(
    val domain: String,
    val readOnly: Boolean,
    val paused: Boolean,
    val pendingUploads: Int,
    val pendingDownloads: Int,
    val uploading: List<Upload>,
    val downloading: List<Download>,
    val pendingBytes: Long,
    /** Why the domain is not syncing, when it is not. */
    val failing: String? = null,
    /** The reply itself, for Copy report (activity §2.6). */
    val raw: String = "",
)

/** What the owner's `stats` report says about this domain's local storage and stuck work. */
data class Stats(
    val cacheBytes: Long?,
    val pinnedBytes: Long?,
    val parked: Int,
    val lastError: String?,
    /** 05 §2.1 rule 5: in force, and whether they are the server's list. */
    val extensions: List<String> = emptyList(),
    val extensionsFromServer: Boolean = false,
    val maxCache: Long? = null,
    val mainOffline: Boolean = false,
    val setAside: Int = 0,
    val syncPending: Int = 0,
    val syncFailing: String? = null,
    val cannotFollow: CannotFollow? = null,
    val versioning: Boolean? = null,
    val readOnly: Boolean? = null,
    val symlinks: String? = null,
    val chunkSize: Long? = null,
    val stores: List<StoreReport> = emptyList(),
    val recentErrors: List<LogLine> = emptyList(),
    /** The owner process's own RAM (status text's `own_ram`). */
    val ownRam: Long? = null,
    /** The reply itself, for Copy report (activity §2.6). */
    val raw: String = "",
)

data class CannotFollow(val entry: Int, val reason: String)

data class LogLine(val time: Double, val level: String, val message: String)

/** One of the domain's stores as `stats` reports it (activity §2.4). */
data class StoreReport(
    val name: String,
    val role: String?,
    val reachable: Boolean?,
    val latencyMs: Double?,
    val unreachable: String?,
    val down: Boolean,
    val heldForSeconds: Double,
    val failures: Int,
    val downReason: String?,
    val damagedChunks: Int,
    val damagedTruncated: Boolean,
    val freeBytes: Long?,
    val totalBytes: Long?,
    val copiesOwed: Int,
    val copiesRate: Double,
    val copying: String?,
    val copyChecked: Int,
    val copyChunks: Int,
) {
    val hasProblem: Boolean get() = down || reachable == false || damagedChunks > 0

    internal companion object {
        fun of(o: JSONObject): StoreReport {
            val reach = o.optJSONObject("reach")
            val health = o.optJSONObject("health")
            val corrupted = o.optJSONObject("corrupted")
            val disk = o.optJSONObject("disk")
            val copies = o.optJSONObject("copies")
            val job = copies?.optJSONObject("current")
            return StoreReport(
                name = o.optString("name", ""),
                role = text(o, "role"),
                reachable = reach?.takeIf { it.has("reachable") }?.optBoolean("reachable"),
                latencyMs = reach?.takeIf { it.has("latencyMs") }?.optDouble("latencyMs"),
                unreachable = reach?.let { text(it, "error") },
                down = health?.optString("state") == "down",
                heldForSeconds = health?.optDouble("heldForSeconds", 0.0) ?: 0.0,
                failures = health?.optInt("failures", 0) ?: 0,
                downReason = health?.let { text(it, "reason") },
                damagedChunks = if (corrupted?.optBoolean("checked", false) == true) corrupted.optInt("chunks", 0) else 0,
                damagedTruncated = corrupted?.optBoolean("truncated", false) ?: false,
                freeBytes = disk?.takeIf { it.has("freeBytes") }?.optLong("freeBytes"),
                totalBytes = disk?.takeIf { it.has("totalBytes") }?.optLong("totalBytes"),
                copiesOwed = copies?.optInt("owed", 0) ?: 0,
                copiesRate = copies?.optDouble("jobsPerSec", 0.0) ?: 0.0,
                copying = job?.let { text(it, "path") ?: text(it, "job") },
                copyChecked = job?.optInt("checked", 0) ?: 0,
                copyChunks = job?.optInt("chunks", 0) ?: 0,
            )
        }
    }
}

/** android §3.2 rule 1; [BACKGROUND] answers the last view at once. */
enum class Pull(val wire: String?) { DEFAULT(null), NOW("now"), NEVER("never"), BACKGROUND("background") }

internal fun JSONObject.pull(pull: Pull): JSONObject = apply { pull.wire?.let { put("pull", it) } }

internal fun text(row: JSONObject, key: String): String? =
    if (row.has(key) && !row.isNull(key)) row.optString(key, "") else null

/** The requests the app sends (08 §3.3, android.md §6). */
object Requests {
    private fun action(name: String) = JSONObject().put("action", name)

    fun stat(ref: String) = action("stat").put("ref", ref)
    fun statChild(parentRef: String, name: String) = action("stat").put("parentRef", parentRef).put("name", name)

    fun listDir(ref: String, after: String?, limit: Int?, pull: Pull): JSONObject {
        val request = action("list_dir").put("ref", ref)
        after?.let { request.put("after", it) }
        limit?.let { request.put("limit", it) }
        pull.wire?.let { request.put("pull", it) }
        return request
    }

    fun mkdir(parentRef: String, name: String, exclusive: Boolean) = child("mkdir", parentRef, name, exclusive)
    fun create(parentRef: String, name: String, exclusive: Boolean) = child("create", parentRef, name, exclusive)

    private fun child(verb: String, parentRef: String, name: String, exclusive: Boolean) =
        action(verb).put("parentRef", parentRef).put("name", name).put("exclusive", exclusive)

    fun writeChild(parentRef: String, name: String, staging: String, base: String?, exclusive: Boolean, createdNs: Long? = null): JSONObject {
        val request = action("write").put("parentRef", parentRef).put("name", name)
        return write(request, staging, base, createdNs).put("exclusive", exclusive)
    }

    fun writeRef(ref: String, staging: String, base: String?, createdNs: Long? = null) =
        write(action("write").put("ref", ref), staging, base, createdNs)

    /** [createdNs]: the file's creation time, which the staging file cannot hold (08 §3.3). */
    private fun write(request: JSONObject, staging: String, base: String?, createdNs: Long?): JSONObject {
        request.put("staging", staging).put("await", true)
        base?.let { request.put("base", it) }
        createdNs?.let { request.put("createdNs", it) }
        return request
    }

    fun rename(ref: String, parentRef: String, name: String) =
        action("rename").put("ref", ref).put("parentRef", parentRef).put("name", name).put("noreplace", true)

    fun delete(ref: String) = action("delete").put("ref", ref)
    fun rmdir(ref: String) = action("rmdir").put("ref", ref)
    fun ensureCached(ref: String, dest: String) = action("ensure_cached").put("ref", ref).put("dest", dest)
    fun share(ref: String) = action("share").put("ref", ref)
    fun evict(ref: String) = action("evict").put("ref", ref)
    fun restore(ref: String) = action("restore").put("ref", ref)
    fun status() = action("status")
    fun stats() = action("stats").put("arg", "frontend")
    fun pause(paused: Boolean) = action("pause").put("arg", if (paused) "on" else "off")
    fun retry() = action("retry")
}

/** Typed requests over the bridge. Every failure is a [CoreException] carrying its code. */
class Client(private val core: Core) {
    fun call(request: JSONObject): JSONObject {
        val reply = try {
            JSONObject(core.request(request.toString()))
        } catch (e: org.json.JSONException) {
            throw CoreException(Code.INTERNAL, "the core answered something that is not a reply")
        }
        if (reply.optBoolean("ok", false)) return reply
        val occupant = reply.optJSONObject("item")?.takeIf { it.has("ref") }?.let(Item::of)
        throw CoreException(Code.of(text(reply, "code")), reply.optString("error", "request failed"), occupant)
    }

    private fun item(request: JSONObject): Item = Item.of(call(request).getJSONObject("item"))

    fun stat(ref: String): Item = Item.of(call(Requests.stat(ref)))
    fun statChild(parentRef: String, name: String): Item = Item.of(call(Requests.statChild(parentRef, name)))

    fun listDir(ref: String, after: String? = null, limit: Int? = null, pull: Pull = Pull.DEFAULT): Listing {
        val reply = call(Requests.listDir(ref, after, limit, pull))
        return Listing(
            items = items(reply.optJSONArray("items")),
            next = text(reply, "next"),
            pulledAt = if (reply.has("pulledAt") && !reply.isNull("pulledAt")) reply.optLong("pulledAt") else null,
            outdated = reply.optBoolean("outdated", false),
        )
    }

    /** Every page of a folder (app §5: a listing follows `next` until the end). */
    fun listAll(ref: String, pull: Pull = Pull.DEFAULT): Listing {
        val first = listDir(ref, pull = pull)
        val items = first.items.toMutableList()
        var next = first.next
        while (next != null) {
            val page = listDir(ref, after = next)
            items += page.items
            next = page.next
        }
        return first.copy(items = items, next = null)
    }

    fun mkdir(parentRef: String, name: String, exclusive: Boolean): Item = item(Requests.mkdir(parentRef, name, exclusive))
    fun create(parentRef: String, name: String): Item = item(Requests.create(parentRef, name, true))

    fun writeChild(parentRef: String, name: String, staging: String, base: String?, exclusive: Boolean, createdNs: Long? = null): Item =
        item(Requests.writeChild(parentRef, name, staging, base, exclusive, createdNs))

    fun writeRef(ref: String, staging: String, base: String?, createdNs: Long? = null): Item =
        item(Requests.writeRef(ref, staging, base, createdNs))
    fun rename(ref: String, parentRef: String, name: String): Item = item(Requests.rename(ref, parentRef, name))

    fun delete(item: Item) {
        call(if (item.isDir) Requests.rmdir(item.ref) else Requests.delete(item.ref))
    }

    fun ensureCached(ref: String, dest: String): Item = item(Requests.ensureCached(ref, dest))

    fun share(ref: String): ShareLink {
        val reply = call(Requests.share(ref))
        return ShareLink(reply.getString("url"), reply.optLong("expires", 0))
    }

    fun evict(ref: String): Counts = call(Requests.evict(ref)).let { Counts(it.optInt("evicted", 0), it.optInt("failed", 0)) }
    fun restore(ref: String): Counts = call(Requests.restore(ref)).let { Counts(it.optInt("restored", 0), it.optInt("failed", 0)) }
    fun pause(paused: Boolean): Boolean = call(Requests.pause(paused)).optBoolean("paused", paused)
    fun retry(): Int = call(Requests.retry()).optInt("readopted", 0)

    fun status(): Status {
        val reply = call(Requests.status())
        return Status(
            domain = reply.optString("domain", ""),
            readOnly = reply.optBoolean("readOnly", false),
            paused = reply.optBoolean("paused", false),
            pendingUploads = reply.optInt("pendingUploads", 0),
            pendingDownloads = reply.optInt("pendingDownloads", 0),
            uploading = objects(reply.optJSONArray("uploading")).map {
                Upload(it.optString("name", ""), if (it.has("size")) it.optLong("size") else null, it.optLong("bytes", 0), it.optDouble("rate", 0.0))
            },
            downloading = objects(reply.optJSONArray("downloading")).map {
                Download(it.optString("name", ""), it.optLong("bytes", 0), it.optLong("size", 0), it.optDouble("rate", 0.0))
            },
            pendingBytes = reply.optLong("pendingBytes", 0),
            failing = text(reply, "failing")?.takeIf { it.isNotEmpty() },
            raw = reply.toString(2),
        )
    }

    fun stats(): Stats {
        val reply = call(Requests.stats())
        val body = if (reply.has("cache")) reply else reply.optJSONArray("domains")?.optJSONObject(0) ?: reply
        val cache = body.optJSONObject("cache")
        val queues = body.optJSONObject("queues")
        val settings = body.optJSONObject("settings")
        val extensions = settings?.optJSONArray("extensions")
        val sync = body.optJSONObject("sync")
        val self = reply.optJSONObject("self")
        val usage = self?.optJSONObject("process")
        return Stats(
            cacheBytes = cache?.takeIf { it.has("bytes") }?.optLong("bytes"),
            pinnedBytes = cache?.takeIf { it.has("pinnedBytes") }?.optLong("pinnedBytes"),
            parked = queues?.optInt("parked", 0) ?: 0,
            lastError = queues?.let { text(it, "lastError") }?.takeIf { it.isNotEmpty() },
            extensions = if (extensions == null) emptyList() else (0 until extensions.length()).map { extensions.optString(it) },
            extensionsFromServer = settings?.optJSONObject("domainWide")?.optString("extensions") == "main",
            maxCache = cache?.takeIf { it.has("maxCache") && !it.isNull("maxCache") }?.optLong("maxCache"),
            mainOffline = body.optBoolean("mainOffline", false),
            setAside = body.optInt("setAside", 0),
            syncPending = sync?.optInt("pending", 0) ?: 0,
            syncFailing = sync?.let { text(it, "failing") }?.takeIf { it.isNotEmpty() },
            cannotFollow = sync?.optJSONObject("cannotFollow")?.let { CannotFollow(it.optInt("entry"), it.optString("reason")) },
            versioning = settings?.takeIf { it.has("versioning") }?.optBoolean("versioning"),
            readOnly = settings?.takeIf { it.has("readOnly") }?.optBoolean("readOnly"),
            symlinks = settings?.let { text(it, "symlinks") },
            chunkSize = settings?.takeIf { it.has("chunkSize") }?.optLong("chunkSize"),
            stores = objects(body.optJSONArray("backends")).map(StoreReport::of),
            recentErrors = objects(self?.optJSONArray("recentErrors")).map {
                LogLine(it.optDouble("t", 0.0), it.optString("level", ""), it.optString("message", ""))
            },
            ownRam = usage?.let { u -> if (u.has("anonymousBytes") && !u.isNull("anonymousBytes")) u.optLong("anonymousBytes") else u.takeIf { it.has("privateBytes") }?.optLong("privateBytes") },
            raw = reply.toString(2),
        )
    }

    private fun items(rows: JSONArray?): List<Item> = objects(rows).map(Item::of)

}

internal fun objects(rows: JSONArray?): List<JSONObject> =
    if (rows == null) emptyList() else (0 until rows.length()).map { rows.getJSONObject(it) }
