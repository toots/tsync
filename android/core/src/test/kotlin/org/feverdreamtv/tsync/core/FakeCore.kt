package org.feverdreamtv.tsync.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** An in-memory owner answering the actions the app sends, for logic tests. */
class FakeCore(private val domain: String = "Family Photos") : Core {
    class Node(val ref: String, var parent: String, var name: String, val dir: Boolean) {
        var content = ByteArray(0)
        var mtime = 0.0
    }

    val nodes = linkedMapOf("root" to Node("root", "root", domain, true))
    val requests = mutableListOf<JSONObject>()
    var refuse: (JSONObject) -> Pair<String, String>? = { null }
    var outdated = false
    var pageLimit = 1000
    private var minted = 0

    fun add(parent: String, name: String, dir: Boolean = false, content: String = ""): Node {
        val id = (++minted).toString().padStart(if (dir) 4 else 32, '0')
        val node = Node(if (dir) "d:$id" else "i:$id", parent, name, dir)
        node.content = content.toByteArray()
        nodes[node.ref] = node
        return node
    }

    fun child(parent: String, name: String): Node? = nodes.values.firstOrNull { it.parent == parent && it.name == name && it.ref != "root" }
    fun names(parent: String): List<String> = nodes.values.filter { it.parent == parent && it.ref != "root" }.map { it.name }.sorted()

    override fun checkConfig(domain: String, candidate: String?): String? = null
    override fun boot(domain: String): String? = null
    override fun status(): String = "status"
    override fun open(ref: String): Long = -2
    override fun size(handle: Long): Long = -9
    override fun read(handle: Long, offset: Long, length: Int, dest: ByteArray): Int = -9
    override fun close(handle: Long): Int = 0

    override fun request(json: String): String {
        val request = JSONObject(json)
        requests += request
        refuse(request)?.let { return failure(it.first, it.second) }
        return try {
            answer(request).put("ok", true).toString()
        } catch (e: Refusal) {
            failure(e.code, e.message!!, e.occupant)
        }
    }

    private class Refusal(val code: String, message: String, val occupant: Node? = null) : Exception(message)

    private fun failure(code: String, error: String, occupant: Node? = null): String {
        val reply = JSONObject().put("ok", false).put("code", code).put("error", error)
        occupant?.let { reply.put("item", row(it)) }
        return reply.toString()
    }

    private fun contentId(node: Node) = "%016x".format(node.content.contentHashCode().toLong() and 0xffffffffL)

    fun row(node: Node): JSONObject {
        val row = JSONObject().put("ref", node.ref).put("parentRef", node.parent).put("name", node.name)
            .put("kind", if (node.dir) "dir" else "file").put("size", node.content.size).put("mtime", node.mtime)
            .put("etag", if (node.dir) node.ref else contentId(node)).put("isUploaded", true)
        if (!node.dir) row.put("contentId", contentId(node)).put("availability", "cached")
        return row
    }

    private fun resolve(request: JSONObject): Node {
        if (request.has("ref")) return nodes[request.getString("ref")] ?: throw Refusal("not_found", "no such item")
        folder(request.getString("parentRef"))
        return child(request.getString("parentRef"), request.getString("name")) ?: throw Refusal("not_found", "no such item")
    }

    private fun folder(ref: String): Node = nodes[ref]?.takeIf { it.dir } ?: throw Refusal("not_found", "no such folder")

    private fun answer(request: JSONObject): JSONObject = when (request.getString("action")) {
        "stat" -> row(resolve(request))
        "list_dir" -> list(request)
        "mkdir" -> item(make(request, dir = true))
        "create" -> item(make(request, dir = false))
        "write" -> item(write(request))
        "rename" -> item(rename(request))
        "delete", "rmdir" -> JSONObject().also { nodes.remove(resolve(request).ref) }
        else -> throw Refusal("invalid", "unknown action")
    }

    private fun item(node: Node) = JSONObject().put("item", row(node))

    private fun list(request: JSONObject): JSONObject {
        val folder = folder(request.getString("ref"))
        val after = request.optString("after", "")
        val limit = minOf(request.optInt("limit", pageLimit), pageLimit)
        val rest = nodes.values.filter { it.parent == folder.ref && it.ref != "root" && it.name > after }.sortedBy { it.name }
        val page = rest.take(limit)
        val reply = JSONObject().put("items", JSONArray(page.map(::row))).put("pulledAt", 1755347464L)
        if (rest.size > limit) reply.put("next", page.last().name)
        if (outdated) reply.put("outdated", true)
        return reply
    }

    private fun make(request: JSONObject, dir: Boolean): Node {
        val parent = folder(request.getString("parentRef"))
        val existing = child(parent.ref, request.getString("name"))
        if (existing != null) {
            if (request.optBoolean("exclusive", false) || !dir) throw Refusal("exists", "the name is taken", existing)
            return existing
        }
        return add(parent.ref, request.getString("name"), dir)
    }

    private fun write(request: JSONObject): Node {
        val staging = File(request.getString("staging"))
        val node = if (request.has("ref")) resolve(request) else {
            val parent = folder(request.getString("parentRef"))
            val existing = child(parent.ref, request.getString("name"))
            if (existing != null && request.optBoolean("exclusive", false)) throw Refusal("exists", "the name is taken", existing)
            existing ?: add(parent.ref, request.getString("name"))
        }
        node.content = staging.readBytes()
        node.mtime = staging.lastModified() / 1000.0
        staging.delete()
        return node
    }

    private fun rename(request: JSONObject): Node {
        val node = resolve(JSONObject().put("ref", request.getString("ref")))
        val parent = folder(request.getString("parentRef"))
        val occupant = child(parent.ref, request.getString("name"))
        if (occupant != null && occupant !== node) throw Refusal("exists", "the name is taken", occupant)
        node.parent = parent.ref
        node.name = request.getString("name")
        return node
    }
}
