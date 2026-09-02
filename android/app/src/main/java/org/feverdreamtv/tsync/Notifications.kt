package org.feverdreamtv.tsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

/**
 * The notifications the app posts, and the channels behind them.
 *
 * The two that say why the app is holding the foreground are quiet by design:
 * [NotificationManager.IMPORTANCE_LOW] posts without a sound and stays out of
 * the way of whatever the user is actually doing. A problem is not.
 */
object Notifications {

    /** Ids are per-app, so they are handed out here rather than by whoever
     *  posts one: two features choosing the same number replace each other's
     *  notification, which reads as one of them never having posted. */
    const val BACKUP_ID = 2
    const val OPEN_DOCUMENTS_ID = 3
    const val PROBLEM_ID = 4

    const val BACKUP_CHANNEL = "tsync-backup"
    const val OPEN_DOCUMENTS_CHANNEL = "tsync-open-documents"
    const val PROBLEM_CHANNEL = "tsync-problems"

    /** Something the user did that did not take, said out loud: a save whose
     *  body the domain would not adopt is otherwise a log line nobody reads. */
    fun problem(context: Context, text: String) {
        context.getSystemService(NotificationManager::class.java).notify(
            PROBLEM_ID,
            build(context, PROBLEM_CHANNEL, "Problems", text,
                NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

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
        text: String,
        importance: Int = NotificationManager.IMPORTANCE_LOW
    ): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(channel, channelName, importance)
        )
        return Notification.Builder(context, channel)
            .setContentTitle("tsync")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(R.drawable.ic_notification)
            .build()
    }
}
