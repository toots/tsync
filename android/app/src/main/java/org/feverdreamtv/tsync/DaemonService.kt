package org.feverdreamtv.tsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import org.feverdreamtv.tsync.backup.NetworkGate
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

        /** Long enough to mean it started properly rather than died on config. */
        const val SETTLED_MS = 60_000L
        const val RESTART_DELAY_MS = 5_000L
        const val MAX_RESTARTS = 5

        /** Android 15 stops a dataSync foreground service after roughly six
         *  hours a day and refuses to start another until the next window, so
         *  the service gives up the budget as soon as nothing is owed. */
        const val IDLE_CHECK_MS = 60_000L
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

    /** Set while onDestroy is tearing down, so the pump does not read the exit
     *  it asked for as a death to recover from. */
    @Volatile
    private var stopping = false
    private var restarts = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, notification())
        // Liveness, not nullness: the daemon is an exec'd child rather than a
        // process the system manages, so Android reaps it on its own while this
        // service object survives. Holding a dead Process here is what left it
        // down until something killed the whole app.
        if (daemon?.isAlive != true) start()
        return START_STICKY
    }

    /**
     * The platform's warning that this service's foreground budget is spent; it
     * has seconds to comply before the process is killed as if it had crashed.
     */
    override fun onTimeout(startId: Int) = surrenderForeground()

    override fun onTimeout(startId: Int, fgsType: Int) = surrenderForeground()

    private fun surrenderForeground() {
        Log.w(TAG, "foreground service timed out; stopping")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun start() {
        val process = Runtime.getRuntime().exec(
            arrayOf(binary(this).absolutePath, "start"),
            env(this)
        )
        daemon = process
        // Local, not a field: a restart would otherwise stamp this thread's
        // process with the successor's start time.
        val launchedAt = SystemClock.elapsedRealtime()
        // Without syslog compiled in, Log.Daemon falls through to stdout, so this
        // pump is the only way to see anything the daemon says.
        Thread {
            process.inputStream.bufferedReader().forEachLine { Log.i(TAG, it) }
            // EOF means it exited: Android reaps this child on its own, and a
            // picker in another app needs it back without anyone opening ours.
            val lived = SystemClock.elapsedRealtime() - launchedAt
            Log.w(TAG, "daemon exited ${process.waitFor()} after ${lived / 1000}s")
            if (lived > SETTLED_MS) restarts = 0
            when {
                stopping -> {}
                // A daemon that dies immediately dies for a reason a retry will
                // not change — say so once instead of spinning on it.
                ++restarts > MAX_RESTARTS ->
                    Log.e(TAG, "daemon died $MAX_RESTARTS times in a row; leaving it down")
                else -> {
                    Thread.sleep(RESTART_DELAY_MS)
                    if (!stopping) start()
                }
            }
        }.start()
        Thread {
            process.errorStream.bufferedReader().forEachLine { Log.w(TAG, it) }
        }.start()
        // The pause flag lives in the daemon's memory, so a restart forgets that
        // uploads were being held back for a metered network.
        Thread {
            if (Daemon.awaitReady(this)) {
                NetworkGate.apply(this)
                watchForIdle()
            }
        }.start()
    }

    /**
     * Gives the foreground budget back once nothing is owed.
     *
     * Android 15 stops a dataSync service after about six hours a day and
     * refuses to start another until the window rolls over, so holding one open
     * on an idle daemon spends the allowance that the next backup needs.
     */
    private fun watchForIdle() {
        while (!stopping) {
            Thread.sleep(IDLE_CHECK_MS)
            val status = runCatching { Daemon.status(this) }.getOrNull() ?: continue
            if (Daemon.isIdle(status)) {
                Log.i(TAG, "queues are empty; releasing the foreground service")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
        }
    }

    override fun onDestroy() {
        stopping = true
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
