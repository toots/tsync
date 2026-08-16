package org.feverdreamtv.tsync

import android.content.Context
import android.content.Intent
import org.json.JSONObject
import java.io.File

/**
 * Reaching the daemon, and asking it to be there.
 *
 * Everything that wants the daemon up goes through here, because Ipc.serve
 * unlinks and rebinds the socket (lib/transport/ipc/ipc.ml): a second daemon
 * started while the first is alive takes the socket over and both then write to
 * one store.
 */
object Daemon {

    fun socket(context: Context): File =
        Ipc.socketPath(context.filesDir, Config.load(context)?.domain ?: "")

    fun status(context: Context): JSONObject = Ipc.send(socket(context), "status")

    /**
     * Whether the daemon answers, which is not the same as whether its socket
     * file exists: the file outlives the process that bound it, so a path that
     * is present and listens to nothing reads as a running daemon.
     */
    fun isAnswering(context: Context): Boolean =
        runCatching { status(context) }.isSuccess

    /** Blocks until the daemon answers, up to [timeoutMs]. */
    fun awaitReady(context: Context, timeoutMs: Long = 10_000): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (isAnswering(context)) return true
            Thread.sleep(250)
        }
        return isAnswering(context)
    }

    /** Starts the service only if nothing is already answering. */
    fun ensureRunning(context: Context, timeoutMs: Long = 30_000): Boolean {
        if (isAnswering(context)) return true
        context.startForegroundService(Intent(context, DaemonService::class.java))
        return awaitReady(context, timeoutMs)
    }

    /**
     * Holds uploads at the queue rather than in flight, so a batch handed over
     * on wifi does not finish over cellular.
     *
     * The daemon keeps this in memory, so a caller that wants it to stick has to
     * say so again after every restart.
     */
    fun setPaused(context: Context, paused: Boolean) {
        Ipc.send(socket(context), "pause", mapOf("arg" to if (paused) "on" else "off"))
    }

    /** Nothing owed and nothing moving, which is when the service may stop. */
    fun isIdle(status: JSONObject): Boolean =
        status.optInt("pendingUploads") == 0 &&
            status.optInt("pendingDownloads") == 0 &&
            status.optJSONArray("uploading").let { it == null || it.length() == 0 }

    fun pendingBytes(status: JSONObject): Long = status.optLong("pendingBytes")

    fun pendingUploads(status: JSONObject): Int = status.optInt("pendingUploads")
}
