package org.feverdreamtv.tsync

import android.net.LocalSocket
import android.net.LocalSocketAddress
import org.json.JSONObject
import java.io.File

/**
 * The daemon's IPC socket on a device. Mirrors macos/TsyncFileProvider/IPC.swift.
 *
 * A filesystem socket, not the abstract namespace: abstract names are visible
 * device-wide, so any app could talk to the daemon.
 */
object Ipc {
    /** The app's files dir is the daemon's HOME (DaemonService.env). */
    fun socketPath(filesDir: File, domain: String): File = DaemonPaths.socket(filesDir, domain)

    /** Bounds a daemon that accepted the connection and then wedged. Connect
     *  needs no timeout of its own: a filesystem socket with nothing listening
     *  is refused at once. */
    const val READ_TIMEOUT_MS = 30_000

    fun send(socket: File, action: String, fields: Map<String, Any> = emptyMap()): JSONObject {
        val conn = LocalSocket()
        try {
            conn.connect(
                LocalSocketAddress(socket.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM)
            )
            conn.soTimeout = READ_TIMEOUT_MS
            return IpcWire.wire(
                conn.inputStream, conn.outputStream, IpcWire.request(action, fields)
            )
        } finally {
            runCatching { conn.close() }
        }
    }
}
