package org.feverdreamtv.tsync

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Holds the process out of the cached state for as long as a file the app is
 * serving is open.
 *
 * A proxy descriptor is answered in this process ({!TsyncProvider}), and the
 * system freezes a cached process: a player reading through one gets its bytes
 * until the buffer runs out and then waits for a read nothing will ever answer.
 * Being foreground is the only thing that keeps the process running while
 * nothing of the app is on screen.
 *
 * It does nothing but exist. What decides whether it should be running is
 * [OpenDescriptors], and the two are wired together in [start] and [stop] so
 * that no caller has to know both.
 */
class OpenDocumentsService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    /** Android 15 gives a dataSync service a few hours a day and then asks it
     *  to stop, killing the process if it does not. Reads go on being served
     *  for as long as the process lives, which is what happens without the
     *  service at all. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i(TAG, "foreground time is up; serving without it")
        stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val open = OpenDescriptors.count
        val notification = Notifications.build(
            this,
            Notifications.OPEN_DOCUMENTS_CHANNEL,
            "Open files",
            if (open == 1) "Serving an open file" else "Serving $open open files"
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                Notifications.OPEN_DOCUMENTS_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(Notifications.OPEN_DOCUMENTS_ID, notification)
        }
        // Nothing to resume: a descriptor does not survive the process, so a
        // restarted service would hold the foreground for files nobody has open.
        return START_NOT_STICKY
    }

    companion object {
        const val TAG = "tsync-open"

        /**
         * Take a descriptor, starting the service if this is the first.
         *
         * The platform may refuse: a background start is barred outside a few
         * exemptions, and a dataSync service is stopped once it has had its
         * hours for the day. Refused, the descriptor still works and reads are
         * served exactly as long as the process happens to live -- which is what
         * happens without any of this.
         */
        fun retain(context: Context) {
            if (!OpenDescriptors.retain()) return
            runCatching {
                context.startForegroundService(
                    Intent(context, OpenDocumentsService::class.java)
                )
            }.onFailure {
                Log.i(TAG, "serving without the foreground: ${it.message}")
            }
        }

        /** Give one back, stopping the service once none is left. */
        fun release(context: Context) {
            if (!OpenDescriptors.release()) return
            runCatching {
                context.stopService(Intent(context, OpenDocumentsService::class.java))
            }.onFailure { Log.i(TAG, "could not stop: ${it.message}") }
        }
    }
}
