package org.feverdreamtv.tsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log
import java.io.File

/**
 * Runs the tsync daemon as a child process.
 *
 * The binary ships as jniLibs/arm64-v8a/libtsync.so purely so it lands in
 * nativeLibraryDir, which is the only place an app may exec from since API 29.
 * It is an ordinary executable, not a shared object.
 */
class DaemonService : Service() {
    companion object {
        const val TAG = "tsyncd"
        private const val CHANNEL = "tsync-daemon"
        private const val NOTIFICATION_ID = 1

        fun binary(context: Context): File =
            File(context.applicationInfo.nativeLibraryDir, "libtsync.so")

        /** Everything the daemon locates — config, cache, data, sockets — hangs
         *  off HOME (see lib/runtime/linux_runtime.ml), so one variable
         *  redirects it into the app sandbox. Not cacheDir: the OS may reap that
         *  while the daemon holds chunks. */
        fun env(context: Context): Array<String> =
            arrayOf("HOME=${context.filesDir.absolutePath}")

        fun run(context: Context, vararg args: String): Pair<Int, String> {
            val process = Runtime.getRuntime().exec(
                arrayOf(binary(context).absolutePath) + args,
                env(context)
            )
            val output = process.inputStream.bufferedReader().readText() +
                process.errorStream.bufferedReader().readText()
            return process.waitFor() to output
        }
    }

    private var daemon: Process? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, notification())
        if (daemon == null) start()
        return START_STICKY
    }

    private fun start() {
        val process = Runtime.getRuntime().exec(
            arrayOf(binary(this).absolutePath, "start"),
            env(this)
        )
        daemon = process
        // Without syslog compiled in, Log.Daemon falls through to stdout, so this
        // pump is the only way to see anything the daemon says.
        Thread {
            process.inputStream.bufferedReader().forEachLine { Log.i(TAG, it) }
        }.start()
        Thread {
            process.errorStream.bufferedReader().forEachLine { Log.w(TAG, it) }
        }.start()
    }

    override fun onDestroy() {
        // Ask it to drain first; the handler returns `Stop and unwinds cleanly.
        runCatching { run(this, "stop") }
        daemon?.destroy()
        daemon = null
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "tsync daemon", NotificationManager.IMPORTANCE_LOW)
        )
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("tsync")
            .setContentText("Daemon running")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .build()
    }
}
