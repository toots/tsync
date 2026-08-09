package org.feverdreamtv.tsync

import android.net.LocalSocket
import android.net.LocalSocketAddress
import org.json.JSONObject
import java.io.File

/**
 * Client for the daemon's IPC socket: one JSON object per line, one request per
 * connection. Mirrors macos/TsyncFileProvider/IPC.swift.
 *
 * A filesystem socket, not the abstract namespace: abstract names are visible
 * device-wide, so any app could talk to the daemon.
 */
object Ipc {
    /** Matches Runtime.default_paths with HOME set to the app's files dir. */
    fun socketPath(filesDir: File, domain: String): File =
        File(filesDir, ".local/share/tsync/tsync-$domain.sock")

    class Error(message: String) : Exception(message)

    /** Values are typed: the daemon reads offsets and lengths as JSON numbers
     *  and ignores a string spelling of one. */
    fun send(socket: File, action: String, fields: Map<String, Any> = emptyMap()): JSONObject {
        val request = JSONObject().put("action", action)
        fields.forEach { (k, v) -> request.put(k, v) }

        val conn = LocalSocket()
        try {
            conn.connect(LocalSocketAddress(socket.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM))
            conn.outputStream.write((request.toString() + "\n").toByteArray())
            conn.outputStream.flush()
            conn.shutdownOutput()

            val line = conn.inputStream.bufferedReader().readLine()
                ?: throw Error("daemon closed the connection without replying")
            val response = JSONObject(line)
            if (!response.optBoolean("ok")) {
                throw Error(response.optString("error", "request failed: $action"))
            }
            return response
        } finally {
            runCatching { conn.close() }
        }
    }
}
