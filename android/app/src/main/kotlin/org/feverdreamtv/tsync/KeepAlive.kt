package org.feverdreamtv.tsync

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.feverdreamtv.tsync.core.KeepAliveCounter
import org.feverdreamtv.tsync.core.KeepAliveCounter.Work

/** app §9: a foreground service for as long as descriptor reads or commits are running. */
class KeepAlive(private val context: Context) {
    val counter = KeepAliveCounter()

    fun retain(work: Work) {
        if (counter.retain(work)) start() else KeepAliveService.running?.refresh()
    }

    fun release(work: Work) {
        counter.release(work)
        KeepAliveService.running?.refresh()
    }

    private fun start() {
        try {
            context.startForegroundService(Intent(context, KeepAliveService::class.java))
        } catch (e: RuntimeException) {
            // Background restrictions or an exhausted budget: the work goes on while the process lives.
            Log.w(Tsync.TAG, "keep-alive service refused", e)
        }
    }
}

class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        running = this
        refresh()
        // Nothing it held survives the process, so the platform must not restart it.
        return START_NOT_STICKY
    }

    /** Shows what is held, or stops when nothing is. Always goes foreground first: the platform demands it of a started service. */
    fun refresh() {
        val held = Tsync.get(this).keepAlive.counter.held()
        try {
            val notification = Notifications.keepAlive(this, held)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: RuntimeException) {
            // A started service that never goes foreground gets the process killed; stopped, the
            // work goes on for as long as the process lives (app §9).
            Log.w(Tsync.TAG, "keep-alive service cannot go foreground", e)
            stopSelf()
            return
        }
        if (held.total == 0) stop()
    }

    private fun stop() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    // app §15: letting the platform's timeout fire kills the process.
    override fun onTimeout(startId: Int) = stop()

    override fun onTimeout(startId: Int, fgsType: Int) = stop()

    override fun onDestroy() {
        running = null
    }

    companion object {
        const val NOTIFICATION_ID = 1

        @Volatile
        var running: KeepAliveService? = null
            private set
    }
}
