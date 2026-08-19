package org.feverdreamtv.tsync.backup

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager

/**
 * The conditions the user asked a backup to keep to.
 *
 * A job constraint decides whether the job starts; this is checked again inside
 * it, since a sweep runs for minutes and the network it began on is not
 * necessarily the one it finishes on.
 */
object NetworkGate {

    private const val LOW_BATTERY_PERCENT = 15

    /** Null when a backup may run, else why it is being held. */
    fun blockedBecause(context: Context): String? {
        val prefs = BackupPrefs(context)
        if (prefs.unmeteredOnly && isMetered(context)) return "waiting for wifi"
        if (prefs.whenBatteryOk && isBatteryLow(context)) return "battery low"
        return null
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
