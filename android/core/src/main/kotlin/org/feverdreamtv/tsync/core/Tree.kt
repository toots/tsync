package org.feverdreamtv.tsync.core

object Tree {
    /** app §7: true iff the document's parent chain reaches `parent`. False at the root and on any failure. */
    fun isChild(client: Client, parent: String, document: String): Boolean {
        var current = document
        repeat(Parameters.MAX_TREE_DEPTH) {
            if (current == Parameters.ROOT) return false
            val above = try {
                client.stat(current).parentRef
            } catch (e: CoreException) {
                return false
            }
            if (above == parent) return true
            if (above == current) return false
            current = above
        }
        return false
    }

    /** Whether `folder` is `ancestor` or lies in its subtree: a move there would detach it. */
    fun isWithin(client: Client, ancestor: String, folder: String): Boolean =
        folder == ancestor || isChild(client, ancestor, folder)
}

/** A disposable path → folder reference cache (app §8.3). */
interface FolderCache {
    fun get(path: String): String?
    fun put(path: String, ref: String)
    fun remove(path: String)
}

class Folders(private val client: Client, private val cache: FolderCache) {
    /** Resolves a domain path to its folder, making what is missing; `mkdir` answers an existing folder. */
    fun folderFor(path: String): String {
        if (path.isEmpty()) return Parameters.ROOT
        cache.get(path)?.let { return it }
        val parent = folderFor(Naming.parentPath(path))
        val ref = try {
            client.mkdir(parent, Naming.leaf(path), exclusive = false).ref
        } catch (e: CoreException) {
            if (e.code == Code.NOT_FOUND) forget(Naming.parentPath(path))
            throw e
        }
        cache.put(path, ref)
        return ref
    }

    /** A cached reference answered `not_found`: the next resolution asks again. */
    fun forget(path: String) {
        if (path.isNotEmpty()) cache.remove(path)
    }
}

/** app §5: `unreachable` or an outdated listing latches; only `recovered` or a fresh listing clears. */
class OfflineLatch(private val changed: (Boolean) -> Unit = {}) {
    @Volatile
    var offline = false
        private set

    fun failed(error: CoreException) {
        if (error.code == Code.UNREACHABLE) set(true)
    }

    fun listed(listing: Listing) = set(listing.outdated)

    fun recovered() = set(false)

    @Synchronized
    private fun set(value: Boolean) {
        if (offline == value) return
        offline = value
        changed(value)
    }
}
