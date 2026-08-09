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
         *  while the daemon holds chunks.
         *
         *  SSL_CERT_FILE is not optional. conduit forces its default
         *  authenticator when it builds a context — for plain HTTP as much as
         *  for HTTPS — and ca-certs only looks at /etc/ssl paths that Android
         *  does not have, so without this the daemon dies at startup. */
        fun env(context: Context): Array<String> = arrayOf(
            "HOME=${context.filesDir.absolutePath}",
            "SSL_CERT_FILE=${caBundle(context).absolutePath}"
        )

        private val CA_DIRECTORIES = listOf(
            "/apex/com.android.conscrypt/cacerts",  // canonical since Android 14
            "/system/etc/security/cacerts"
        )

        /**
         * Concatenate the device's trust store into the single bundle file
         * ca-certs expects. Built from the system store rather than shipped in
         * the APK so it tracks the device's own roots instead of going stale.
         *
         * Android's cert files carry human-readable text after the PEM block,
         * so only the blocks themselves are taken.
         */
        fun caBundle(context: Context): File {
            val bundle = File(context.filesDir, "ca-bundle.pem")
            if (bundle.exists() && bundle.length() > 0) return bundle

            val source = CA_DIRECTORIES.map(::File).firstOrNull { it.isDirectory }
            if (source == null) {
                Log.w(TAG, "no system CA directory found; TLS will not verify")
                return bundle
            }

            val begin = "-----BEGIN CERTIFICATE-----"
            val end = "-----END CERTIFICATE-----"
            bundle.bufferedWriter().use { out ->
                var count = 0
                source.listFiles()?.forEach { certificate ->
                    runCatching {
                        val text = certificate.readText()
                        var from = text.indexOf(begin)
                        while (from >= 0) {
                            val to = text.indexOf(end, from)
                            if (to < 0) break
                            out.write(text.substring(from, to + end.length))
                            out.write("\n")
                            count++
                            from = text.indexOf(begin, to)
                        }
                    }
                }
                Log.i(TAG, "CA bundle: $count certificates from $source")
            }
            return bundle
        }

        /** Whether a full sync this app started is still going. The app owns
         *  that subprocess, so this is the one thing it can say honestly: the
         *  daemon runs in another process and is not told about the walk. */
        @Volatile
        var syncRunning: Boolean = false
            private set

        /** Minutes of work on a large domain, so the caller runs it off the
         *  main thread and reads the exit code: a resync that could not finish
         *  reports non-zero rather than leaving a half-mirror looking whole. */
        fun runFullSync(context: Context): Pair<Int, String> {
            syncRunning = true
            return try {
                run(context, "sync", "--full")
            } finally {
                syncRunning = false
            }
        }

        fun run(context: Context, vararg args: String): Pair<Int, String> {
            val process = Runtime.getRuntime().exec(
                arrayOf(binary(context).absolutePath) + args,
                env(context)
            )
            val output = process.inputStream.bufferedReader().readText() +
                process.errorStream.bufferedReader().readText()
            val code = process.waitFor()
            // Also to logcat: the caller shows this in a toast, and a resync
            // that names the objects it could not fetch says it once, into a
            // message that is gone in four seconds.
            val summary = "${args.joinToString(" ")} exited $code\n${output.trim()}"
            if (code == 0) Log.i(TAG, summary) else Log.w(TAG, summary)
            return code to output
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
