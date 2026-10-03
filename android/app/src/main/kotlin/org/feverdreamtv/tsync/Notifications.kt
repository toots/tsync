package org.feverdreamtv.tsync

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import org.feverdreamtv.tsync.core.Committed
import org.feverdreamtv.tsync.core.KeepAliveCounter
import org.feverdreamtv.tsync.ui.MainActivity

object Notifications {
    private const val BACKUP = "camera-backup"
    private const val OPEN_FILES = "open-files"
    private const val PROBLEMS = "problems"
    const val BACKUP_ID = 2

    private fun manager(context: Context) = context.getSystemService(NotificationManager::class.java)

    private fun builder(context: Context, channel: String, name: Int, importance: Int): Notification.Builder {
        manager(context).createNotificationChannel(NotificationChannel(channel, context.getString(name), importance))
        val open = Intent(context, MainActivity::class.java).putExtra(MainActivity.EXTRA_SHOW_ACTIVITY, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val tap = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(context, channel).setSmallIcon(R.drawable.ic_notification).setContentIntent(tap)
    }

    fun keepAlive(context: Context, held: KeepAliveCounter.Held): Notification {
        val resources = context.resources
        val lines = listOfNotNull(
            held.openFiles.takeIf { it > 0 }?.let { resources.getQuantityString(R.plurals.serving_open_files, it, it) },
            held.saves.takeIf { it > 0 }?.let { resources.getQuantityString(R.plurals.saving_files, it, it) },
        )
        return builder(context, OPEN_FILES, R.string.channel_open_files, NotificationManager.IMPORTANCE_LOW)
            .setContentTitle(lines.joinToString(" · ").ifEmpty { context.getString(R.string.app_name) })
            .setOngoing(true).build()
    }

    fun backupRunning(context: Context): Notification =
        builder(context, BACKUP, R.string.channel_camera_backup, NotificationManager.IMPORTANCE_LOW)
            .setContentTitle(context.getString(R.string.backup_running)).setOngoing(true).build()

    /** Each problem has its own identity, so one never replaces another (app §3). */
    fun problem(tsync: Tsync, identity: String, title: String, text: String) =
        post(tsync, PROBLEMS, R.string.channel_problems, NotificationManager.IMPORTANCE_DEFAULT, identity, title, text)

    /** How a long action left running ended (app §10.4). */
    fun outcome(tsync: Tsync, identity: String, title: String, text: String) =
        post(tsync, OPEN_FILES, R.string.channel_open_files, NotificationManager.IMPORTANCE_LOW, identity, title, text)

    private fun post(tsync: Tsync, channel: String, name: Int, importance: Int, identity: String, title: String, text: String) {
        val context = tsync.context
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        // The permission can only be asked from a screen: the activity asks at its next start.
        if (!allowed) tsync.notificationsWanted.value = true
        val notification = builder(context, channel, name, importance).setContentTitle(title).setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text)).setAutoCancel(true).build()
        manager(context).notify(identity, 0, notification)
    }

    fun saveOutcome(tsync: Tsync, staging: String, name: String?, result: Result<Committed>) {
        val context = tsync.context
        val label = name ?: context.getString(R.string.shared_file)
        result.onSuccess { committed ->
            if (committed.rerouted) {
                problem(tsync, staging, context.getString(R.string.save_rerouted_title, committed.item.name), context.getString(R.string.save_rerouted_text, tsync.domain))
            }
        }.onFailure { error ->
            problem(tsync, staging, context.getString(R.string.save_failed_title, label), error.message ?: error.toString())
        }
    }

    fun unreadableSave(tsync: Tsync, staging: String) {
        val context = tsync.context
        problem(tsync, staging, context.getString(R.string.save_unreadable_title), context.getString(R.string.save_unreadable_text, staging))
    }
}
