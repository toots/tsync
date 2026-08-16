package org.feverdreamtv.tsync.backup

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.util.Log
import org.feverdreamtv.tsync.Daemon

/**
 * Holds the daemon's upload queue to the conditions the user asked for.
 *
 * A job constraint only decides whether the job runs: once photos are handed
 * over, Sync_queue uploads them on whatever network is there (lib/sync/file.ml
 * queue_put), so a batch staged on wifi would otherwise finish over cellular.
 */
object NetworkGate {

    private const val TAG = "tsync-backup"
    private const val LOW_BATTERY_PERCENT = 15

    /** Null when uploads may run, else why they are being held. */
    fun blockedBecause(context: Context): String? {
        val prefs = BackupPrefs(context)
        if (prefs.unmeteredOnly && isMetered(context)) return "waiting for wifi"
        if (prefs.whenBatteryOk && isBatteryLow(context)) return "battery low"
        return null
    }

    fun apply(context: Context) {
        val blocked = blockedBecause(context)
        runCatching { Daemon.setPaused(context, blocked != null) }
            .onFailure { Log.w(TAG, "pause: ${it.message}") }
    }

    private fun isMetered(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
            ?: return true
        return !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    private fun isBatteryLow(context: Context): Boolean {
        val battery = context.registerReceiver(
            null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        ) ?: return false

        val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        if (status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        ) {
            return false
        }

        val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return false
        return level * 100 / scale < LOW_BATTERY_PERCENT
    }
}
