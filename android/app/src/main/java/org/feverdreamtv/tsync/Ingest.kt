package org.feverdreamtv.tsync

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * The one way bytes enter a domain from this app.
 *
 * The picker and the camera backup differ in where the bytes come from — a
 * descriptor another app writes to, or a copy this app makes — and agree from
 * [commit] onwards.
 */
object Ingest {

    private fun stagingDir(context: Context): File =
        File(context.filesDir, "staging").apply { mkdirs() }

    /**
     * The name carries the time, because [commit] rewrites the modification
     * time to the content's own and [sweepOrphans] would then read a staged
     * holiday photo as long abandoned.
     */
    fun newStaging(context: Context): File =
        stagingDir(context).resolve("${System.currentTimeMillis()}-${UUID.randomUUID()}")

    /**
     * Hands [staging] to the daemon as the whole new content of [key].
     *
     * The daemon adopts the file by rename (Data.stage_whole, lib/content/data.ml),
     * so it is gone on success and must not be deleted here; one it could not
     * take over is, a truncated write being worse than a dropped edit.
     */
    fun commit(socket: File, key: String, staging: File, modified: Long? = null) {
        // The rename into the chunk store is immediate, so bytes still only in
        // page cache when the power goes would be published as the whole file.
        FileOutputStream(staging, true).use { it.fd.sync() }
        if (modified != null) staging.setLastModified(modified)
        try {
            Ipc.send(socket, "write", mapOf("path" to key, "staging" to staging.absolutePath))
        } catch (failure: Exception) {
            staging.delete()
            throw failure
        }
    }

    /**
     * Creates every ancestor folder of [key] that the daemon has no id for,
     * outermost first, recording them in [known].
     *
     * An upload mints a missing id as a side effect but writes no Mkdir journal
     * entry, leaving list_dir answering not_found and the file naming the domain
     * root as its parent (ipc_handler.ml handle_list_dir, handle_stat).
     */
    fun ensureDirs(socket: File, root: String, key: String, known: MutableSet<String>) {
        for (directory in Keys.ancestors(root, key)) {
            if (directory in known) continue
            if (!exists(socket, directory)) {
                Ipc.send(socket, "mkdir", mapOf("path" to directory))
            }
            known.add(directory)
        }
    }

    /** A directory the daemon holds no folder id for reads as absent. */
    private fun exists(socket: File, key: String): Boolean =
        try {
            Ipc.send(socket, "stat", mapOf("path" to key))
            true
        } catch (absent: IpcWire.Error) {
            false
        }

    /**
     * Deletes staged bodies older than [age] that no write ever claimed, which a
     * process death between staging and [commit] leaves behind.
     */
    fun sweepOrphans(context: Context, age: Long) {
        val cutoff = System.currentTimeMillis() - age
        stagingDir(context).listFiles()?.forEach { staged ->
            val stagedAt = staged.name.substringBefore('-').toLongOrNull()
            if (stagedAt != null && stagedAt < cutoff) staged.delete()
        }
    }
}
