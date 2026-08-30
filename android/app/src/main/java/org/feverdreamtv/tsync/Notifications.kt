package org.feverdreamtv.tsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

/**
 * The notifications the app posts, and the channels behind them.
 *
 * Both of them exist to say why the app is holding the foreground, so both are
 * quiet by design: [NotificationManager.IMPORTANCE_LOW] posts without a sound
 * and stays out of the way of whatever the user is actually doing.
 */
object Notifications {

    /** Ids are per-app, so they are handed out here rather than by whoever
     *  posts one: two features choosing the same number replace each other's
     *  notification, which reads as one of them never having posted. */
    const val BACKUP_ID = 2
    const val OPEN_DOCUMENTS_ID = 3

    const val BACKUP_CHANNEL = "tsync-backup"
    const val OPEN_DOCUMENTS_CHANNEL = "tsync-open-documents"

    /**
     * A notification on [channel], whose channel is created if it is not there.
     *
     * Creating it every time is what the platform asks for: a channel is
     * created once and updated after that, and there is no cheaper way to know
     * whether this is the first time in this install.
     */
    fun build(
        context: Context,
        channel: String,
        channelName: String,
        text: String
    ): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(channel, channelName, NotificationManager.IMPORTANCE_LOW)
        )
        return Notification.Builder(context, channel)
            .setContentTitle("tsync")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification)
            .build()
    }
}
