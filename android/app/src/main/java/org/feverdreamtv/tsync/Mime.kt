package org.feverdreamtv.tsync

import android.webkit.MimeTypeMap

/** What a file is, as far as its name says: the type the picker reports and
 *  another app opens it with, and the icon the list shows. */
object Mime {
    fun of(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    fun icon(mime: String): Int = when (mime.substringBefore('/')) {
        "image" -> R.drawable.ic_image
        "video" -> R.drawable.ic_video
        "audio" -> R.drawable.ic_audio
        else -> R.drawable.ic_file
    }
}
