package org.feverdreamtv.tsync

import org.json.JSONObject

/**
 * The domain's wire: what a request says, and what comes back.
 *
 * Kept clear of anything Android so the request shape and the reply shape can
 * be driven against a real binary from a JVM test, through `tsync android
 * request` — that being the seam that drifts, the two sides agreeing on it by
 * having the same strings written out in OCaml and in Kotlin. The app sends
 * the same requests through the linked runtime.
 *
 * An item is named by reference — "root", "d:<folder id>" or
 * "f:<folder id>/<leaf>" — each of which says which kind it names. What is
 * being made says its own kind too, and so names a parent and a leaf.
 */
object Cli {

    class Error(message: String) : Exception(message)

    /** The daemon's name for a domain's root folder. Every other reference is
     *  learned from a listing, folder ids being the daemon's to mint. */
    const val ROOT = "root"

    /** Whether a reference names a folder, which its own tag says. */
    fun isDir(ref: String) = ref == ROOT || ref.startsWith(DIR)

    /** The folder a container reference names, or null if it names a file.
     *  [rootFolderId] is what the daemon reserves for a domain's root. */
    fun folderId(ref: String, rootFolderId: String): String? = when {
        ref == ROOT -> rootFolderId
        ref.startsWith(DIR) -> ref.removePrefix(DIR)
        else -> null
    }

    /** Whether [ref] is a child of the folder [folderId] names. */
    fun isChildOf(ref: String, folderId: String) =
        ref.startsWith("$FILE$folderId/") || ref == "$DIR$folderId"

    private const val DIR = "d:"
    private const val FILE = "f:"

    private fun request(action: String, vararg fields: Pair<String, Any>): String {
        val request = JSONObject().put("action", action)
        for ((name, value) in fields) request.put(name, value)
        return request.toString()
    }

    fun stat(ref: String) = request("stat", "ref" to ref)

    /** One page of [ref]'s children: [limit] of them past the name [after],
     *  the reply naming the next page's [after] as "next" while there is one. */
    fun list(ref: String, after: String = "", limit: Int? = null) =
        if (limit == null) request("list_dir", "ref" to ref, "after" to after)
        else request("list_dir", "ref" to ref, "after" to after, "limit" to limit)

    /** A link to [ref], file or folder, for anyone holding it. */
    fun share(ref: String) = request("share", "ref" to ref)

    /** The whole content into [dest], for editing in place. */
    fun fetch(ref: String, dest: String) =
        request("ensure_cached", "ref" to ref, "dest" to dest)

    /** The domain adopts [staging] by rename, so it is gone on success. Answers
     *  once the upload has been sent or has started failing, which is what a
     *  caller feeding it files paces on; "isUploaded" says which. */
    fun writeWhole(parent: String, name: String, staging: String) =
        request("write", "parentRef" to parent, "name" to name,
            "staging" to staging, "await" to true)

    fun create(parent: String, name: String) =
        request("create", "parentRef" to parent, "name" to name)

    fun mkdir(parent: String, name: String) =
        request("mkdir", "parentRef" to parent, "name" to name)

    fun delete(ref: String) = request("delete", "ref" to ref)

    fun rmdir(ref: String) = request("rmdir", "ref" to ref)

    /** A move names where it lands the way a creation does. */
    fun rename(ref: String, parent: String, name: String) =
        request("rename", "ref" to ref, "parentRef" to parent, "name" to name)

    /**
     * A refusal is a reply, not an exit code: `ok: false` with a code is how a
     * missing key arrives.
     */
    fun reply(stdout: String): JSONObject {
        val line = stdout.trim()
        if (line.isEmpty()) throw Error("the domain answered nothing")
        val response = try {
            JSONObject(line)
        } catch (malformed: Exception) {
            throw Error("unparseable reply: ${line.take(200)}")
        }
        if (!response.optBoolean("ok")) {
            throw Error(response.optString("error", "request failed"))
        }
        return response
    }
}
