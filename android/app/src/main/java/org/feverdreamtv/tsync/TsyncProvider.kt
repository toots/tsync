package org.feverdreamtv.tsync

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.system.ErrnoException
import android.system.OsConstants
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.util.Log
import android.webkit.MimeTypeMap
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

/**
 * Exposes a tsync domain through the Storage Access Framework.
 *
 * documentId *is* the tsync storage key, verbatim and opaque — the same
 * identity the macOS File Provider uses, so it is stable across restarts with
 * no mapping table. Directories carry a trailing slash, matching
 * lib/daemon/ipc_handler/ipc_handler.ml.
 */
class TsyncProvider : DocumentsProvider() {

    /** Read per call rather than cached: the provider outlives a trip through
     *  the settings screen, and a stale domain would point at a dead socket. */
    private val domain: String
        get() = Config.load(context!!)?.domain ?: "media"

    private val rootDocumentId get() = Keys.root(domain)

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
        // Demand-paged: the platform services each read through the callback
        // below, so a player starts on the first frame instead of waiting for a
        // whole film to land. The descriptor is seekable like any file, which is
        // what container probing needs.
        if (!mode.contains("w")) {
            val size = Ipc.send(socket, "stat", mapOf("path" to documentId)).getLong("size")
            // Ranges land at their own offset, so this is a sparse partial mirror
            // of the file rather than a buffer, and one open never sees another's
            // bytes.
            val scratch = File(context!!.cacheDir, "ranges").apply { mkdirs() }
                .resolve(UUID.randomUUID().toString())
            val storage = context!!.getSystemService(StorageManager::class.java)
            return storage.openProxyFileDescriptor(
                ParcelFileDescriptor.MODE_READ_ONLY,
                object : ProxyFileDescriptorCallback() {
                    override fun onGetSize(): Long = size

                    override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
                        val served = try {
                            val response = Ipc.send(socket, "fetch_range", mapOf(
                                "path" to documentId,
                                "dest" to scratch.absolutePath,
                                "offset" to offset,
                                "length" to size
                            ))
                            response.getInt("length")
                        } catch (e: Exception) {
                            Log.w(TAG, "fetch_range $documentId @$offset: ${e.message}")
                            throw ErrnoException("onRead", OsConstants.EIO)
                        }
                        // Short at end of file, and the caller is told so rather
                        // than handed the zeros the sparse hole would read as.
                        if (served <= 0) return 0
                        RandomAccessFile(scratch, "r").use { file ->
                            file.seek(offset)
                            file.readFully(data, 0, served)
                        }
                        return served
                    }

                    override fun onRelease() {
                        scratch.delete()
                    }
                },
                callbackHandler
            )
        }

        val staging = Ingest.newStaging(context!!)
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
                runCatching { Ingest.commit(socket, documentId, staging) }
                    .onFailure { Log.w(TAG, "write $documentId: ${it.message}") }
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
