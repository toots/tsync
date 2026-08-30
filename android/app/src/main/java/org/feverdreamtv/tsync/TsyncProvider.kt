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

/**
 * Exposes a tsync domain through the Storage Access Framework.
 *
 * documentId *is* the daemon's reference for an item — "root", "d:<folder id>"
 * or "f:<folder id>/<leaf>".
 *
 * A folder's id is minted once and a rename does not touch it, so a documentId
 * survives the folder moving. The reference also says which kind it names,
 * which a caller has to know before it can ask anything.
 */
class TsyncProvider : DocumentsProvider() {

    /** Read per call rather than cached: the provider outlives a trip through
     *  the settings screen, and a stale domain would name the wrong root. */
    private val domain: String
        get() = Config.load(context!!)?.domain ?: "media"

    private val rootDocumentId get() = Cli.ROOT

    /** A descriptor's callbacks all arrive on the handler's thread, so a single
     *  one would serialise every read of every open file in the app. Fixed and
     *  made once: each is registered with the OCaml runtime for as long as it
     *  lives, and the interleaving that matters happens on the Lwt loop. */
    private val callbackHandlers = mutableListOf<Handler>()
    private val nextHandler = java.util.concurrent.atomic.AtomicInteger(0)

    override fun onCreate(): Boolean {
        repeat(CALLBACK_THREADS) { index ->
            val thread = HandlerThread("tsync-pfd-$index").apply { start() }
            callbackHandlers += Handler(thread.looper)
        }
        return true
    }

    private fun handler(): Handler =
        callbackHandlers[
            (nextHandler.getAndIncrement() and Int.MAX_VALUE) % callbackHandlers.size
        ]

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
            .add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
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
            addDirectory(cursor, documentId, "tsync")
        } else {
            // The name is the daemon's to give: a reference spells a folder id,
            // not what anyone called it.
            val response = Tsync.json(context!!, Cli.stat(documentId))
            val name = response.getString("name")
            val modified = (response.optDouble("mtime") * 1000).toLong()
            if (Cli.isDir(documentId)) addDirectory(cursor, documentId, name, modified)
            else addFile(cursor, documentId, name, response.optLong("size"), modified)
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
            val response = Tsync.json(context!!, Cli.list(parentDocumentId))
            // One list, each entry tagged by kind and naming itself by the
            // reference a caller addresses it with.
            val items = response.getJSONArray("items")
            for (i in 0 until items.length()) {
                val entry = items.getJSONObject(i)
                val ref = entry.getString("ref")
                val name = entry.getString("name")
                val modified = (entry.optDouble("mtime", 0.0) * 1000).toLong()
                if (entry.getString("kind") == "dir") addDirectory(cursor, ref, name, modified)
                else addFile(cursor, ref, name, entry.optLong("size"), modified)
            }
        } catch (e: Exception) {
            // A banner in the picker beats an empty folder that looks like truth.
            // A folder is read when it is opened, so a failure here is the
            // server being out of reach rather than anything left undone.
            cursor.extras = android.os.Bundle().apply {
                putString(android.provider.DocumentsContract.EXTRA_ERROR,
                    "tsync could not reach the server for this folder")
            }
            Log.w(TAG, "list_dir $parentDocumentId: ${e.message}")
        }
        return cursor
    }

    /** A file names the folder holding it, so the question is whether that is
     *  this folder. */
    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        val parentId =
            Cli.folderId(parentDocumentId, Keys.ROOT_FOLDER_ID) ?: return false
        return Cli.isChildOf(documentId, parentId)
    }

    // ── Opening ──────────────────────────────────────────────────────────────

    /** A handle and the app's claim on the foreground are taken together: the
     *  reads it will serve are answered in this process, and a process the
     *  system has frozen answers none of them. */
    private fun openHandle(documentId: String): Int {
        val handle = Native.nativeOpen(documentId)
        if (handle < 0) throw ErrnoException("openDocument", -handle)
        OpenDocumentsService.retain(context!!)
        Log.i(TAG, "open $documentId (${OpenDescriptors.count} open)")
        return handle
    }

    /** Both ends a handle can come to go through here, so the count and the
     *  handle cannot drift apart. */
    private fun closeHandle(handle: Int, documentId: String) {
        Native.nativeClose(handle)
        OpenDocumentsService.release(context!!)
        Log.i(TAG, "close $documentId (${OpenDescriptors.count} open)")
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        // The descriptor is seekable like any file, which is what container
        // probing needs.
        if (!mode.contains("w")) {
            val storage = context!!.getSystemService(StorageManager::class.java)
            Native.ensure(context!!)
            val handle = openHandle(documentId)
            // Closed here if the descriptor cannot be made: nothing else would,
            // onRelease belonging to a descriptor that never existed.
            return try {
                storage.openProxyFileDescriptor(
                    ParcelFileDescriptor.MODE_READ_ONLY,
                    object : ProxyFileDescriptorCallback() {
                        override fun onGetSize(): Long = Native.nativeSize(handle)

                        override fun onRead(
                            offset: Long,
                            size: Int,
                            data: ByteArray
                        ): Int {
                            val began = android.os.SystemClock.uptimeMillis()
                            val served = Native.nativeRead(handle, offset, size, data)
                            val took = android.os.SystemClock.uptimeMillis() - began
                            // A read this slow is what a player gives up on, and
                            // what the descriptor is killed for; the ones that
                            // return promptly are the overwhelming majority and
                            // would drown it.
                            if (took >= SLOW_READ_MILLIS) {
                                Log.w(TAG, "read $documentId @$offset+$size took ${took}ms")
                            }
                            // The errno the domain answered, not a blanket EIO:
                            // a document that is gone reads differently from one
                            // that could not be fetched.
                            if (served < 0) throw ErrnoException("onRead", -served)
                            return served
                        }

                        override fun onRelease() {
                            closeHandle(handle, documentId)
                        }
                    },
                    handler()
                )
            } catch (failure: Exception) {
                closeHandle(handle, documentId)
                throw failure
            }
        }

        val staging = Ingest.newStaging(context!!)
        if (mode.contains("r")) {
            // Edit in place: start from the current contents, assembled straight
            // into the file the write will hand back.
            runCatching {
                Tsync.json(context!!, Cli.fetch(documentId, staging.absolutePath))
            }
        }
        if (!staging.exists()) staging.createNewFile()

        return ParcelFileDescriptor.open(
            staging,
            ParcelFileDescriptor.MODE_READ_WRITE,
            handler()
        ) { error ->
            if (error != null) {
                // A truncated write is worse than a dropped edit.
                Log.w(TAG, "write $documentId aborted: $error")
                staging.delete()
            } else {
                // The folder and leaf, which the item names rather than the
                // reference: what is written is where it already is.
                runCatching {
                    val stat = Tsync.json(context!!, Cli.stat(documentId))
                    Ingest.commit(
                        context!!, stat.getString("parentRef"),
                        stat.getString("name"), staging
                    )
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
        val name = Keys.sanitizeLeaf(displayName)
        Tsync.json(
            context!!,
            if (isDirectory) Cli.mkdir(parentDocumentId, name)
            else Cli.create(parentDocumentId, name)
        )
        // The daemon mints a folder's id, so what it is called is asked for
        // rather than composed here.
        return childRef(parentDocumentId, name)
    }

    /** The reference a freshly made child answers to. */
    private fun childRef(parent: String, name: String): String {
        val items = Tsync.json(context!!, Cli.list(parent)).getJSONArray("items")
        for (i in 0 until items.length()) {
            val entry = items.getJSONObject(i)
            if (entry.getString("name") == name) return entry.getString("ref")
        }
        throw IllegalStateException("no child $name under $parent")
    }

    override fun deleteDocument(documentId: String) {
        Tsync.json(
            context!!,
            if (Cli.isDir(documentId)) Cli.rmdir(documentId) else Cli.delete(documentId)
        )
    }

    /** A folder keeps its id across the move, so its documentId is unchanged
     *  and the system's grants beneath it stay good; a file's names its leaf,
     *  so that one moves with it. */
    override fun renameDocument(documentId: String, displayName: String): String {
        val parent = parentOf(documentId)
        val name = Keys.sanitizeLeaf(displayName)
        Tsync.json(context!!, Cli.rename(documentId, parent, name))
        return if (Cli.isDir(documentId)) documentId else childRef(parent, name)
    }

    /** The folder a reference sits in, which a file's own reference names. */
    private fun parentOf(documentId: String): String =
        Tsync.json(context!!, Cli.stat(documentId)).getString("parentRef")

    // ── Row helpers ──────────────────────────────────────────────────────────

    private fun addDirectory(
        cursor: MatrixCursor,
        documentId: String,
        name: String,
        modified: Long = 0
    ) {
        cursor.newRow()
            .add(Document.COLUMN_DOCUMENT_ID, documentId)
            .add(Document.COLUMN_DISPLAY_NAME,
                if (documentId == rootDocumentId) "tsync" else name)
            .add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR)
            .add(Document.COLUMN_FLAGS,
                Document.FLAG_DIR_SUPPORTS_CREATE or Document.FLAG_SUPPORTS_DELETE or
                    Document.FLAG_SUPPORTS_RENAME)
            .add(Document.COLUMN_LAST_MODIFIED, modified.takeIf { it > 0 })
    }

    private fun addFile(
        cursor: MatrixCursor,
        documentId: String,
        name: String,
        size: Long,
        modified: Long
    ) {
        cursor.newRow()
            .add(Document.COLUMN_DOCUMENT_ID, documentId)
            .add(Document.COLUMN_DISPLAY_NAME, name)
            .add(Document.COLUMN_MIME_TYPE, mimeType(name))
            .add(Document.COLUMN_FLAGS,
                Document.FLAG_SUPPORTS_WRITE or Document.FLAG_SUPPORTS_DELETE or
                    Document.FLAG_SUPPORTS_RENAME)
            .add(Document.COLUMN_SIZE, size)
            .add(Document.COLUMN_LAST_MODIFIED, modified.takeIf { it > 0 })
    }

    private fun mimeType(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    companion object {
        const val TAG = "tsyncsaf"

        /** Concurrent reads in flight; beyond this a caller waits rather than
         *  falling into anything slower. */
        const val CALLBACK_THREADS = 4

        /** Long enough that only a read worth knowing about is logged. */
        const val SLOW_READ_MILLIS = 1_000L
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
