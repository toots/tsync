package org.feverdreamtv.tsync.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

object Naming {
    private val cameraTime = DateTimeFormatter.ofPattern("yyyy-MM-dd HH.mm.ss", Locale.ROOT)
    private val sequence = Regex(" \\((\\d+)\\)(\\.[A-Za-z0-9]+)?$")

    /** app §11.5: the leaf of every name the app creates. */
    fun sanitizeLeaf(name: String): String {
        val replaced = name.map { if (it == '/' || it == '\\' || it.isISOControl()) '_' else it }.joinToString("")
        return replaced.trimStart().trimEnd(' ', '.').ifEmpty { "unnamed" }
    }

    /** app §5: `<stem> (<n>)<ext>`; n = 0 is the name itself. */
    fun numbered(name: String, n: Int): String {
        if (n == 0) return name
        val dot = name.lastIndexOf('.')
        return if (dot > 0) "${name.substring(0, dot)} ($n)${name.substring(dot)}" else "$name ($n)"
    }

    fun candidates(name: String): Sequence<String> =
        (0..Parameters.MAX_NAME_ATTEMPTS).asSequence().map { numbered(name, it) }

    /** app §11.5: from the display name, never the MIME type; "" when it has none. */
    fun cameraExtension(displayName: String): String {
        val dot = displayName.lastIndexOf('.')
        if (dot <= 0 || dot == displayName.length - 1) return ""
        val extension = displayName.substring(dot + 1)
        val alphanumeric = extension.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' }
        return if (alphanumeric) "." + extension.lowercase(Locale.ROOT) else ""
    }

    /** The unnumbered camera target of a capture, in the zone the phone is in when first seen. */
    fun cameraTarget(captureMillis: Long, zone: ZoneId, displayName: String): String {
        val time = Instant.ofEpochMilli(captureMillis).atZone(zone)
        return "Camera Uploads/${time.year}/${cameraTime.format(time)}${cameraExtension(displayName)}"
    }

    /** A target with its sequence number removed: the name every capture of that second and type shares. */
    fun unnumbered(target: String): String = sequence.replace(target) { it.groupValues[2] }

    fun parentPath(target: String): String = target.substringBeforeLast('/', "")
    fun leaf(target: String): String = target.substringAfterLast('/')
}
