package org.feverdreamtv.tsync.backup

import org.feverdreamtv.tsync.Keys
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Where a captured photo lands under the domain root.
 *
 * The name is computed once and then kept in the device record: capture time is
 * UTC milliseconds and the zone is whichever one the phone is in at ingest, so
 * recomputing it after the owner has travelled would name the same photo twice.
 */
object PhotoNaming {
    const val FOLDER = "Camera Uploads"

    private val YEAR = DateTimeFormatter.ofPattern("yyyy")
    private val STAMP = DateTimeFormatter.ofPattern("yyyy-MM-dd HH.mm.ss")

    /**
     * [sequence] separates captures that share a second; zero omits the suffix,
     * so the common case reads as a plain timestamp.
     */
    fun relativePath(
        captureMillis: Long,
        displayName: String,
        zone: ZoneId,
        sequence: Int = 0
    ): String {
        val captured = Instant.ofEpochMilli(captureMillis).atZone(zone)
        val suffix = if (sequence == 0) "" else " ($sequence)"
        val leaf = Keys.sanitizeLeaf(captured.format(STAMP) + suffix + extensionOf(displayName))
        return "$FOLDER/${captured.format(YEAR)}/$leaf"
    }

    /** Taken from the name rather than the mime type, which maps HEIC, DNG and
     *  the raw formats to something the file is not. */
    fun extensionOf(displayName: String): String {
        val dot = displayName.lastIndexOf('.')
        if (dot <= 0 || dot == displayName.length - 1) return ""
        val extension = displayName.substring(dot + 1)
        if (!extension.all { it.isLetterOrDigit() }) return ""
        return "." + extension.lowercase()
    }
}
