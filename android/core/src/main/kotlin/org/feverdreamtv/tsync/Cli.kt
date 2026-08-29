package org.feverdreamtv.tsync

import org.json.JSONObject

/**
 * The binary's Android verbs: what to pass, and what comes back.
 *
 * Kept clear of anything Android so the argv and the reply shape can be driven
 * against a real binary from a JVM test — that being the seam that drifts, the
 * two sides agreeing on it by having the same strings written out in OCaml and
 * in Kotlin.
 *
 * An item is named by reference — "root", "d:<folder id>" or
 * "f:<folder id>/<leaf>" — each of which says which kind it names. What is
 * being made says its own kind too, and so names a parent and a leaf.
 *
 * The verbs take positional arguments rather than flags because the binary
 * parses neither: it hands whatever followed the verb to the frontend that owns
 * it.
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

    fun stat(ref: String) = listOf("android", "stat", ref)

    fun list(ref: String) = listOf("android", "list", ref)

    fun read(ref: String, dest: String, offset: Long, length: Int) =
        listOf("android", "read", ref, dest, offset.toString(), length.toString())

    /** How many of the file's chunks are on this device, against how many
     *  there are. */
    fun residency(ref: String) = listOf("android", "residency", ref)

    /** Serves ranges until stdin closes. The app reads through the linked
     *  domain instead; this stays as the verb a person can drive by hand, and
     *  as what CliProtocolTest holds the reply framing to. */
    fun open(ref: String) = listOf("android", "open", ref)

    /** The whole content into [dest], for editing in place. */
    fun fetch(ref: String, dest: String) = listOf("android", "fetch", ref, dest)

    /** The binary adopts [staging] by rename, so it is gone on success. */
    fun writeWhole(parent: String, name: String, staging: String) =
        listOf("android", "write-whole", parent, name, staging)

    fun create(parent: String, name: String) =
        listOf("android", "create", parent, name)

    fun mkdir(parent: String, name: String) =
        listOf("android", "mkdir", parent, name)

    fun delete(ref: String) = listOf("android", "delete", ref)

    fun rmdir(ref: String) = listOf("android", "rmdir", ref)

    /** A move names where it lands the way a creation does. */
    fun rename(ref: String, parent: String, name: String) =
        listOf("android", "rename", ref, parent, name)

    fun status() = listOf("android", "status")

    /**
     * Verbs that change a domain, and the whole-domain walks.
     *
     * These must not run beside each other. The metadata lock and the per-key
     * locks that order them are Lwt mutexes held inside one process
     * (lib/sync/file.ml with_meta, lib/content/data.ml key_locks), which was
     * enough while a domain had exactly one; nothing orders two invocations.
     * Reads take neither lock and are free to run together.
     */
    private val EXCLUSIVE =
        setOf("create", "mkdir", "delete", "rmdir", "rename", "write-whole", "sync")

    /** Whether [args] names one of them, given argv as it will be passed. */
    fun isExclusive(args: List<String>): Boolean =
        args.any { it in EXCLUSIVE }

    /**
     * A refusal is a reply, not an exit code: `ok: false` with a code is how a
     * missing key arrives.
     */
    fun reply(stdout: String): JSONObject {
        val line = stdout.trim()
        if (line.isEmpty()) throw Error("the binary answered nothing")
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
