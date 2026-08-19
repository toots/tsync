package org.feverdreamtv.tsync

/**
 * Storage keys, as the daemon spells them.
 *
 * A key is what the SAF layer calls a documentId, and directories carry a
 * trailing slash — see lib/daemon/ipc_handler/ipc_handler.ml.
 */
object Keys {
    /** tsync/<domain>/manifests/ — see Conf.domain_prefix. */
    fun root(domain: String): String = "tsync/$domain/manifests/"

    /**
     * The directory keys between [root] and [key], outermost first, excluding
     * both.
     *
     * The domain root is not a folder anyone creates.
     */
    fun ancestors(root: String, key: String): List<String> {
        require(key.startsWith(root)) { "$key is not under $root" }
        val segments = key.removePrefix(root).trimEnd('/').split('/')
        if (segments.size < 2) return emptyList()
        return segments.dropLast(1).runningFold(root) { parent, segment ->
            parent + segment + "/"
        }.drop(1)
    }

    /**
     * Makes a leaf safe to concatenate into a key.
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
