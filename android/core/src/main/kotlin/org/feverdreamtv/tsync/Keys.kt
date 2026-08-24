package org.feverdreamtv.tsync

/**
 * Leaf names, as the daemon will file them.
 *
 * Items are named by reference and folder ids are the daemon's to mint, so
 * nothing here composes a path: what a client supplies is the leaf a new item
 * is to be called.
 */
object Keys {
    /** The folder id the daemon reserves for a domain's root — see
     *  Stored_key.root_id. */
    const val ROOT_FOLDER_ID = ".tsync-root"

    /**
     * Makes a leaf safe to file under.
     *
     * Display names come from the camera roll and from other apps, keys are
     * '/'-delimited the whole way down, and a trailing space or dot names a
     * different file than it reads as.
     */
    fun sanitizeLeaf(name: String): String {
        val cleaned = name
            .map { character ->
                if (character == '/' || character == '\\' || character.isISOControl()) {
                    '_'
                } else {
                    character
                }
            }
            .joinToString("")
            .trimStart()
            .trimEnd(' ', '.')
        return cleaned.ifEmpty { "unnamed" }
    }
}
