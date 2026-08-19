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
 * A key is passed verbatim as one argument. The verbs take positional arguments
 * rather than flags because the binary parses neither: it hands whatever
 * followed the verb to the frontend that owns it.
 */
object Cli {

    class Error(message: String) : Exception(message)

    fun stat(key: String) = listOf("android", "stat", key)

    fun list(key: String) = listOf("android", "list", key)

    fun read(key: String, offset: Long, length: Int) =
        listOf("android", "read", key, offset.toString(), length.toString())

    /** The whole content into [dest], for editing in place. */
    fun fetch(key: String, dest: String) = listOf("android", "fetch", key, dest)

    /** The binary adopts [staging] by rename, so it is gone on success. */
    fun writeWhole(key: String, staging: String) =
        listOf("android", "write-whole", key, staging)

    fun create(key: String) = listOf("android", "create", key)

    fun mkdir(key: String) = listOf("android", "mkdir", key)

    fun delete(key: String) = listOf("android", "delete", key)

    fun rmdir(key: String) = listOf("android", "rmdir", key)

    fun rename(from: String, to: String) = listOf("android", "rename", from, to)

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
