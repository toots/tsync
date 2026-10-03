package org.feverdreamtv.tsync.core

import java.io.File
import java.io.IOException

/** The PEM bundle of system authorities the core is given (app §4). */
object TrustBundle {
    private val certificate = Regex("-----BEGIN CERTIFICATE-----[A-Za-z0-9+/=\\s]+?-----END CERTIFICATE-----")

    /** Only complete certificate blocks, from the first directory that holds any. */
    fun collect(directories: List<File>): String? {
        for (directory in directories) {
            val blocks = directory.listFiles().orEmpty().sortedBy { it.name }.flatMap { file ->
                val text = try {
                    file.readText(Charsets.ISO_8859_1)
                } catch (e: IOException) {
                    ""
                }
                certificate.findAll(text).map { it.value }.toList()
            }
            if (blocks.isNotEmpty()) return blocks.joinToString("\n", postfix = "\n")
        }
        return null
    }

    /**
     * Replaces the bundle only when its content differs; a failed rebuild keeps the previous one.
     * @return whether a bundle exists afterwards
     */
    fun refresh(bundle: File, directories: List<File>): Boolean {
        try {
            val content = collect(directories)
            val current = if (bundle.exists()) bundle.readText(Charsets.ISO_8859_1) else null
            if (content != null && content != current) Durable.write(bundle, content.toByteArray(Charsets.ISO_8859_1))
        } catch (e: IOException) {
            // The previous bundle, if any, stays.
        }
        return bundle.exists()
    }
}
