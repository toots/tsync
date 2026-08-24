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
     * Hands [staging] over as the whole new content of [key].
     *
     * The binary adopts the file by rename (Data.stage_whole, lib/content/data.ml),
     * so it is gone on success and must not be deleted here; one it could not
     * take over is, a truncated write being worse than a dropped edit.
     *
     * The call returns once the upload has drained, so it is also what paces a
     * sweep: there is no queue to hand work to and ask about later.
     */
    fun commit(
        context: Context,
        parent: String,
        name: String,
        staging: File,
        modified: Long? = null
    ) {
        // The rename into the chunk store is immediate, so bytes still only in
        // page cache when the power goes would be published as the whole file.
        FileOutputStream(staging, true).use { it.fd.sync() }
        if (modified != null) staging.setLastModified(modified)
        try {
            Tsync.json(context, Cli.writeWhole(parent, name, staging.absolutePath))
        } catch (failure: Exception) {
            staging.delete()
            throw failure
        }
    }

    /**
     * The folder [relativePath]'s file belongs in, making any part of the chain
     * that is not there yet and answering with its reference.
     *
     * A folder is named by an id the daemon mints at mkdir, so there is nothing
     * to write into until it exists. [known] carries what earlier calls
     * resolved, keyed by the relative path each folder holds.
     */
    fun folderFor(
        context: Context,
        relativePath: String,
        known: MutableMap<String, String>
    ): String {
        var parent = Cli.ROOT
        var sofar = ""
        for (segment in relativePath.split('/').dropLast(1)) {
            if (segment.isEmpty()) continue
            sofar = if (sofar.isEmpty()) segment else "$sofar/$segment"
            val cached = known[sofar]
            if (cached != null) {
                parent = cached
                continue
            }
            val existing = childRef(context, parent, segment)
            val ref =
                if (existing != null) existing
                else {
                    Tsync.json(context, Cli.mkdir(parent, segment))
                    childRef(context, parent, segment)
                        ?: throw IllegalStateException("could not create $sofar")
                }
            known[sofar] = ref
            parent = ref
        }
        return parent
    }

    /** The reference a folder's child answers to, or null if it has none. */
    private fun childRef(context: Context, parent: String, name: String): String? =
        try {
            val items = Tsync.json(context, Cli.list(parent)).getJSONArray("items")
            (0 until items.length())
                .map { items.getJSONObject(it) }
                .firstOrNull { it.getString("name") == name }
                ?.getString("ref")
        } catch (absent: Cli.Error) {
            null
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
