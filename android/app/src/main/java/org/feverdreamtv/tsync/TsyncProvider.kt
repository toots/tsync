package org.feverdreamtv.tsync

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.util.Log
import android.webkit.MimeTypeMap
import java.io.File
import java.util.UUID

/**
 * Exposes a tsync domain through the Storage Access Framework.
 *
 * documentId *is* the tsync storage key, verbatim and opaque — the same
 * identity the macOS File Provider uses, so it is stable across restarts with
 * no mapping table. Directories carry a trailing slash, matching
 * lib/ipc_handler/ipc_handler.ml.
 */
class TsyncProvider : DocumentsProvider() {

    /** Read per call rather than cached: the provider outlives a trip through
     *  the settings screen, and a stale domain would point at a dead socket. */
    private val domain: String
        get() = Config.load(context!!)?.domain ?: "media"

    /** tsync/<domain>/manifests/ — see Conf.domain_prefix. */
    private val rootDocumentId get() = "tsync/$domain/manifests/"

    private lateinit var callbackThread: HandlerThread
    private lateinit var callbackHandler: Handler

    private val socket: File
        get() = Ipc.socketPath(context!!.filesDir, domain)

    override fun onCreate(): Boolean {
        callbackThread = HandlerThread("tsync-pfd").apply { start() }
        callbackHandler = Handler(callbackThread.looper)
        return true
    }

    // ── Roots ────────────────────────────────────────────────────────────────

    private val defaultRootColumns = arrayOf(
        Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE,
        Root.COLUMN_FLAGS, Root.COLUMN_ICON
    )

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultRootColumns)
        // Published even when the daemon is down: a root that disappears takes
        // the app out of every file picker and leaves no way to diagnose it.
        cursor.newRow()
            .add(Root.COLUMN_ROOT_ID, domain)
            .add(Root.COLUMN_DOCUMENT_ID, rootDocumentId)
            .add(Root.COLUMN_TITLE, "tsync")
            .add(Root.COLUMN_SUMMARY, domain)
            .add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_CREATE or Root.FLAG_SUPPORTS_IS_CHILD)
            .add(Root.COLUMN_ICON, android.R.drawable.stat_notify_sync)
        return cursor
    }

    // ── Documents ────────────────────────────────────────────────────────────

    private val defaultDocumentColumns = arrayOf(
        Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
        Document.COLUMN_FLAGS, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED
    )

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentColumns)
        if (documentId == rootDocumentId) {
            // Synthesised, not stat'ed: on a fresh install the local manifest
            // mirror does not exist yet and stat would answer "not found",
            // which the picker renders as a dead root.
            addDirectory(cursor, documentId)
        } else if (documentId.endsWith("/")) {
            addDirectory(cursor, documentId)
        } else {
            val response = Ipc.send(socket, "stat", mapOf("path" to documentId))
            addFile(
                cursor, documentId,
                response.optLong("size"),
                (response.optDouble("mtime") * 1000).toLong()
            )
        }
        return cursor
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val cursor = MatrixCursor(projection ?: defaultDocumentColumns)
        try {
            val response = Ipc.send(socket, "list_dir", mapOf("path" to parentDocumentId))
            // One list, each entry tagged by kind. The daemon also names each
            // item by reference, but documentId is the key here, so `key` is
            // what this reads.
            val items = response.getJSONArray("items")
            for (i in 0 until items.length()) {
                val entry = items.getJSONObject(i)
                val key = entry.getString("key")
                val modified = (entry.optDouble("mtime", 0.0) * 1000).toLong()
                if (entry.getString("kind") == "dir") addDirectory(cursor, key, modified)
                else addFile(cursor, key, entry.optLong("size"), modified)
            }
        } catch (e: Exception) {
            // A banner in the picker beats an empty folder that looks like truth.
            cursor.extras = android.os.Bundle().apply {
                putString(android.provider.DocumentsContract.EXTRA_ERROR,
                    "tsync is not running — open the tsync app")
            }
            Log.w(TAG, "list_dir $parentDocumentId: ${e.message}")
        }
        return cursor
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        documentId.startsWith(parentDocumentId)

    // ── Opening ──────────────────────────────────────────────────────────────

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        // Whole-file, as the macOS File Provider does: ensure_cached assembles the
        // content at a destination we name. Ranged reads via
        // openProxyFileDescriptor are a later milestone; nothing here needs them
        // until something tries to stream rather than open.
        if (!mode.contains("w")) {
            val copy = File(context!!.cacheDir, "reads").apply { mkdirs() }
                .resolve(UUID.randomUUID().toString())
            Ipc.send(socket, "ensure_cached",
                mapOf("path" to documentId, "dest" to copy.absolutePath))
            // Our copy, not the daemon's cache entry, so closing it is what ends
            // its life.
            return ParcelFileDescriptor.open(
                copy, ParcelFileDescriptor.MODE_READ_ONLY, callbackHandler
            ) { copy.delete() }
        }

        val staging = File(context!!.filesDir, "staging").apply { mkdirs() }
            .resolve(UUID.randomUUID().toString())
        if (mode.contains("r")) {
            // Edit in place: start from the current contents, assembled straight
            // into the file the write will hand back.
            runCatching {
                Ipc.send(socket, "ensure_cached",
                    mapOf("path" to documentId, "dest" to staging.absolutePath))
            }
        }
        if (!staging.exists()) staging.createNewFile()

        return ParcelFileDescriptor.open(
            staging,
            ParcelFileDescriptor.MODE_READ_WRITE,
            callbackHandler
        ) { error ->
            if (error != null) {
                // A truncated write is worse than a dropped edit.
                Log.w(TAG, "write $documentId aborted: $error")
                staging.delete()
            } else {
                runCatching {
                    // The daemon *renames* the staging file into the chunk store,
                    // so it is gone afterwards — do not delete it here.
                    Ipc.send(socket, "write",
                        mapOf("path" to documentId, "staging" to staging.absolutePath))
                }.onFailure { Log.w(TAG, "write $documentId: ${it.message}") }
            }
        }
    }

    // ── Mutation ─────────────────────────────────────────────────────────────

    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String
    ): String {
        val isDirectory = mimeType == Document.MIME_TYPE_DIR
        val documentId = parentDocumentId + displayName + if (isDirectory) "/" else ""
        Ipc.send(socket, if (isDirectory) "mkdir" else "create", mapOf("path" to documentId))
        return documentId
    }

    override fun deleteDocument(documentId: String) {
        Ipc.send(socket, if (documentId.endsWith("/")) "rmdir" else "delete",
            mapOf("path" to documentId))
    }

    override fun renameDocument(documentId: String, displayName: String): String {
        val parent = documentId.trimEnd('/').substringBeforeLast('/', "") + "/"
        val renamed = parent + displayName + if (documentId.endsWith("/")) "/" else ""
        Ipc.send(socket, "rename", mapOf("src" to documentId, "path" to renamed))
        return renamed
    }

    // ── Row helpers ──────────────────────────────────────────────────────────

    private fun displayName(documentId: String) =
        documentId.trimEnd('/').substringAfterLast('/')

    private fun addDirectory(cursor: MatrixCursor, documentId: String, modified: Long = 0) {
        cursor.newRow()
            .add(Document.COLUMN_DOCUMENT_ID, documentId)
            .add(Document.COLUMN_DISPLAY_NAME,
                if (documentId == rootDocumentId) "tsync" else displayName(documentId))
            .add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
            .add(Document.COLUMN_FLAGS,
                Document.FLAG_DIR_SUPPORTS_CREATE or Document.FLAG_SUPPORTS_DELETE or
                    Document.FLAG_SUPPORTS_RENAME)
            .add(Document.COLUMN_LAST_MODIFIED, modified.takeIf { it > 0 })
    }

    private fun addFile(cursor: MatrixCursor, documentId: String, size: Long, modified: Long) {
        cursor.newRow()
            .add(Document.COLUMN_DOCUMENT_ID, documentId)
            .add(Document.COLUMN_DISPLAY_NAME, displayName(documentId))
            .add(Document.COLUMN_MIME_TYPE, mimeType(documentId))
            .add(Document.COLUMN_FLAGS,
                Document.FLAG_SUPPORTS_WRITE or Document.FLAG_SUPPORTS_DELETE or
                    Document.FLAG_SUPPORTS_RENAME)
            .add(Document.COLUMN_SIZE, size)
            .add(Document.COLUMN_LAST_MODIFIED, modified.takeIf { it > 0 })
    }

    private fun mimeType(documentId: String): String {
        val extension = documentId.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    companion object {
        const val TAG = "tsyncsaf"
        const val AUTHORITY = "org.feverdreamtv.tsync.documents"

        /** DocumentsUI caches the root list and only re-queries when told, so a
         *  root that appears after its first query — a fresh install, or a
         *  domain change — stays invisible until this fires. */
        fun notifyRootsChanged(context: android.content.Context) {
            context.contentResolver.notifyChange(
                android.provider.DocumentsContract.buildRootsUri(AUTHORITY), null
            )
        }
    }
}
