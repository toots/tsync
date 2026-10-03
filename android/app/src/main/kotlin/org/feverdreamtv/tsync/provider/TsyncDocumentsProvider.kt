package org.feverdreamtv.tsync.provider

import android.database.Cursor
import android.database.MatrixCursor
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.system.ErrnoException
import android.system.OsConstants
import android.text.format.DateUtils
import android.webkit.MimeTypeMap
import kotlinx.coroutines.launch
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.Notifications
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Ingest
import org.feverdreamtv.tsync.core.Item
import org.feverdreamtv.tsync.core.KeepAliveCounter.Work
import org.feverdreamtv.tsync.core.Naming
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.Target
import org.feverdreamtv.tsync.core.Tree
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** The domain as documents (app §7). A document id is the item's reference. */
class TsyncDocumentsProvider : DocumentsProvider() {
    private val tsync by lazy { Tsync.get(context!!) }

    // A small fixed set of threads for descriptor callbacks, one assigned per open.
    private val readers by lazy { List(READER_THREADS) { handler("tsync-read-$it") } }
    private val nextReader = AtomicInteger()

    // Close listeners run apart from the readers, so a commit never delays another file's reads.
    private val closer by lazy { handler("tsync-close") }

    // Where each listed folder was, to tell the platform when one is gone.
    private val parents = ConcurrentHashMap<String, String>()

    private fun handler(name: String) = Handler(HandlerThread(name).apply { start() }.looper)

    override fun onCreate(): Boolean = true

    private fun string(id: Int, vararg arguments: Any): String = context!!.getString(id, *arguments)

    /** @throws IllegalStateException with the boot failure, which the platform shows to the caller */
    private fun booted() {
        when (val boot = tsync.boot()) {
            Boot.Ready -> return
            Boot.NoConfig -> throw IllegalStateException(string(R.string.provider_not_set_up))
            is Boot.Failed -> throw IllegalStateException(boot.reason)
        }
    }

    private fun <T> asking(request: org.feverdreamtv.tsync.core.Client.() -> T): T = try {
        tsync.ask(request)
    } catch (e: CoreException) {
        throw if (e.code == Code.NOT_FOUND) FileNotFoundException(e.message) else IllegalStateException(e.message)
    }

    private fun readOnlyDomain(): Boolean = try {
        tsync.boot() == Boot.Ready && tsync.client.stat(Parameters.ROOT).readOnly
    } catch (e: CoreException) {
        false
    }

    // A vanished root leaves no way to diagnose, so there is always one, booted or not.
    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: ROOT_COLUMNS)
        val domain = tsync.config.read()?.domain ?: tsync.domain
        val create = if (tsync.boot() == Boot.Ready && !readOnlyDomain()) Root.FLAG_SUPPORTS_CREATE else 0
        cursor.newRow()
            .add(Root.COLUMN_ROOT_ID, domain.ifEmpty { string(R.string.app_name) })
            .add(Root.COLUMN_DOCUMENT_ID, Parameters.ROOT)
            .add(Root.COLUMN_TITLE, string(R.string.app_name))
            .add(Root.COLUMN_SUMMARY, domain)
            .add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
            .add(Root.COLUMN_FLAGS, Root.FLAG_SUPPORTS_IS_CHILD or create)
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(projection ?: DOCUMENT_COLUMNS)
        if (documentId == Parameters.ROOT) {
            // Synthesised: a fresh install has no mirror to stat.
            val flags = if (readOnlyDomain()) 0 else Document.FLAG_DIR_SUPPORTS_CREATE
            cursor.newRow().add(Document.COLUMN_DOCUMENT_ID, Parameters.ROOT)
                .add(Document.COLUMN_DISPLAY_NAME, tsync.domain.ifEmpty { string(R.string.app_name) })
                .add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR).add(Document.COLUMN_FLAGS, flags)
            return cursor
        }
        booted()
        row(cursor, asking { stat(documentId) })
        return cursor
    }

    private fun row(cursor: MatrixCursor, item: Item) {
        val writable = !item.readOnly
        val common = Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME or Document.FLAG_SUPPORTS_MOVE
        val flags = when {
            !writable -> 0
            item.isDir -> common or Document.FLAG_DIR_SUPPORTS_CREATE
            else -> common or Document.FLAG_SUPPORTS_WRITE
        }
        val row = cursor.newRow().add(Document.COLUMN_DOCUMENT_ID, item.ref)
            .add(Document.COLUMN_DISPLAY_NAME, item.name)
            .add(Document.COLUMN_MIME_TYPE, mimeType(item))
            .add(Document.COLUMN_FLAGS, flags)
        if (!item.isDir) {
            row.add(Document.COLUMN_SIZE, item.size)
            if (item.mtime != 0.0) row.add(Document.COLUMN_LAST_MODIFIED, item.mtimeMillis)
        }
        parents[item.ref] = item.parentRef
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val cursor = ObservedCursor(projection ?: DOCUMENT_COLUMNS, parentDocumentId)
        cursor.setNotificationUri(context!!.contentResolver, DocumentsContract.buildChildDocumentsUri(Tsync.AUTHORITY, parentDocumentId))
        val boot = tsync.boot()
        if (boot != Boot.Ready) {
            return cursor.saying(DocumentsContract.EXTRA_ERROR, (boot as? Boot.Failed)?.reason ?: string(R.string.provider_not_set_up))
        }
        try {
            val listing = tsync.ask { listAll(parentDocumentId) }
            tsync.latch.listed(listing)
            listing.items.forEach { row(cursor, it) }
            if (listing.outdated) cursor.saying(DocumentsContract.EXTRA_INFO, string(R.string.offline_as_of, age(listing.pulledAt)))
        } catch (e: CoreException) {
            when (e.code) {
                Code.UNREACHABLE -> cursor.saying(DocumentsContract.EXTRA_ERROR, string(R.string.cannot_reach_server))
                Code.NOT_FOUND -> {
                    parents.remove(parentDocumentId)?.let(tsync::notifyChildren)
                    cursor.close()
                    throw FileNotFoundException(e.message)
                }
                else -> cursor.saying(DocumentsContract.EXTRA_ERROR, e.message ?: e.code.wire)
            }
        }
        return cursor
    }

    private fun age(pulledAt: Long?): String =
        if (pulledAt == null) string(R.string.unknown_time)
        else DateUtils.formatDateTime(context, pulledAt * 1000, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_ALL)

    /** The folder is observed while the platform holds this result open (app §7.1). */
    private inner class ObservedCursor(columns: Array<out String>, private val folder: String) : MatrixCursor(columns) {
        private var details = Bundle.EMPTY
        private var open = true

        init {
            tsync.observe(folder)
        }

        fun saying(key: String, message: String): ObservedCursor = apply { details = Bundle().apply { putString(key, message) } }

        override fun getExtras(): Bundle = details

        override fun close() {
            if (open) tsync.unobserve(folder)
            open = false
            super.close()
        }
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        tsync.boot() == Boot.Ready && Tree.isChild(tsync.client, parentDocumentId, documentId)

    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        booted()
        val names = Naming.candidates(Naming.sanitizeLeaf(displayName))
        val folder = mimeType == Document.MIME_TYPE_DIR
        return asking {
            Ingest.firstFree(names) { if (folder) mkdir(parentDocumentId, it, exclusive = true) else create(parentDocumentId, it) }
        }.ref
    }

    override fun deleteDocument(documentId: String) {
        booted()
        try {
            tsync.ask { delete(stat(documentId)) }
        } catch (e: CoreException) {
            // Absent already: a delete of it succeeded (failure-model §7.2).
            if (e.code != Code.NOT_FOUND) throw IllegalStateException(e.message)
        }
        revokeDocumentPermission(documentId)
    }

    override fun renameDocument(documentId: String, displayName: String): String? {
        booted()
        val renamed = asking { rename(documentId, stat(documentId).parentRef, Naming.sanitizeLeaf(displayName)) }
        // The platform takes null for "the id did not change", which is every rename here.
        return renamed.ref.takeIf { it != documentId }
    }

    override fun moveDocument(sourceDocumentId: String, sourceParentDocumentId: String, targetParentDocumentId: String): String {
        booted()
        return asking {
            val source = stat(sourceDocumentId)
            if (source.isDir && Tree.isWithin(this, source.ref, targetParentDocumentId)) {
                throw CoreException(Code.INVALID, string(R.string.move_into_itself, source.name))
            }
            rename(source.ref, targetParentDocumentId, source.name)
        }.ref
    }

    override fun getDocumentType(documentId: String): String {
        if (documentId == Parameters.ROOT) return Document.MIME_TYPE_DIR
        booted()
        return mimeType(asking { stat(documentId) })
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        booted()
        return if ('w' in mode) openForWriting(documentId, mode) else openForReading(documentId)
    }

    private fun openForReading(ref: String): ParcelFileDescriptor {
        val handle = tsync.core.open(ref)
        if (handle <= 0) throw FileNotFoundException(string(R.string.cannot_open, OsConstants.errnoName(-handle.toInt()) ?: handle.toString()))
        tsync.keepAlive.retain(Work.OPEN_FILE)
        val callback = object : ProxyFileDescriptorCallback() {
            override fun onGetSize(): Long = positive("size", tsync.core.size(handle))

            override fun onRead(offset: Long, size: Int, data: ByteArray): Int =
                positive("read", tsync.core.read(handle, offset, size, data).toLong()).toInt()

            override fun onRelease() {
                tsync.core.close(handle)
                tsync.keepAlive.release(Work.OPEN_FILE)
            }
        }
        try {
            val storage = context!!.getSystemService(StorageManager::class.java)
            val reader = readers[nextReader.getAndIncrement() % readers.size]
            return storage.openProxyFileDescriptor(ParcelFileDescriptor.MODE_READ_ONLY, callback, reader)
        } catch (e: Exception) {
            callback.onRelease()
            throw FileNotFoundException(e.message)
        }
    }

    private fun positive(call: String, answer: Long): Long {
        if (answer < 0) throw ErrnoException(call, -answer.toInt())
        return answer
    }

    private fun openForWriting(ref: String, mode: String): ParcelFileDescriptor {
        val document = asking { stat(ref) }
        if (document.readOnly) throw FileNotFoundException(string(R.string.read_only_domain))
        tsync.keepAlive.retain(Work.SAVE)
        val ingest = tsync.ingest
        // The intent is durable before the staging file exists or is handed to anyone (app §8.2).
        val name = ingest.stage(Target.Existing(ref, document.name), exclusive = false)
        try {
            val staging = ingest.staging(name)
            val keepsBody = ('r' in mode || 'a' in mode) && 't' !in mode
            val base = if (keepsBody) {
                // Starting empty would publish a truncated file on close, so a failed fetch refuses the open.
                tsync.ask { ensureCached(ref, staging.path) }.contentId
            } else {
                staging.createNewFile()
                document.contentId
            }
            ingest.update(name) { it.copy(base = base) }
            val access = ParcelFileDescriptor.MODE_READ_WRITE or if ('a' in mode) ParcelFileDescriptor.MODE_APPEND else 0
            return ParcelFileDescriptor.open(staging, access, closer) { failure -> closed(name, document.name, failure) }
        } catch (e: Exception) {
            ingest.abandon(name)
            tsync.keepAlive.release(Work.SAVE)
            throw FileNotFoundException(e.message)
        }
    }

    private fun closed(name: String, label: String, failure: IOException?) {
        val ingest = tsync.ingest
        if (failure != null) {
            // A truncated write is worse than a dropped edit.
            ingest.abandon(name)
            tsync.keepAlive.release(Work.SAVE)
            return
        }
        try {
            ingest.markReady(name)
        } catch (e: Exception) {
            ingest.abandon(name)
            tsync.keepAlive.release(Work.SAVE)
            Notifications.problem(tsync, name, string(R.string.save_failed_title, label), e.message ?: e.toString())
            return
        }
        tsync.scope.launch {
            try {
                Notifications.saveOutcome(tsync, name, label, runCatching { ingest.commit(name) })
            } finally {
                tsync.keepAlive.release(Work.SAVE)
            }
        }
    }

    companion object {
        private const val READER_THREADS = 4

        private val ROOT_COLUMNS = arrayOf(
            Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE, Root.COLUMN_SUMMARY, Root.COLUMN_ICON, Root.COLUMN_FLAGS,
        )
        private val DOCUMENT_COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            Document.COLUMN_FLAGS, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED,
        )

        fun mimeType(item: Item): String = if (item.isDir) Document.MIME_TYPE_DIR else mimeType(item.name)

        fun mimeType(name: String): String {
            val extension = name.substringAfterLast('.', "").lowercase()
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
        }
    }
}
