package org.feverdreamtv.tsync.autofill

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.launch
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.Notifications
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Saved

/**
 * passwords/android §5. A changed password is updated only from the notification's button; the
 * password it carries lives in the notification's pending intent, which the system holds for this
 * app alone, until it is tapped or dismissed.
 */
object Saving {
    private const val CHANNEL = "passwords"
    private const val ACTION_UPDATE = "org.feverdreamtv.tsync.autofill.UPDATE"
    private const val EXTRA_SITE = "site"
    private const val EXTRA_USERNAME = "username"
    private const val EXTRA_PASSWORD = "password"
    private const val EXTRA_UPDATE = "update"

    fun save(tsync: Tsync, site: String, username: String, password: String, update: String?) {
        val context = tsync.context
        val identity = "save:$site:$username"
        try {
            if (tsync.boot() != Boot.Ready) throw CoreException(Code.UNREACHABLE, context.getString(R.string.save_login_not_ready))
            when (val saved = tsync.passwords.save(site, username, password, update)) {
                is Saved.Done -> {
                    tsync.vaultChanges.value++
                    Notifications.outcome(tsync, identity, context.getString(R.string.save_login_done, site), username)
                }
                Saved.Unchanged -> {}
                is Saved.Update -> offerUpdate(context, identity, site, username, password, saved.id)
            }
        } catch (e: CoreException) {
            val reason = if (e.code == Code.LOCKED) context.getString(R.string.save_login_locked) else e.message.orEmpty()
            Notifications.problem(tsync, identity, context.getString(R.string.save_login_failed, site), reason)
        }
    }

    private fun offerUpdate(context: Context, identity: String, site: String, username: String, password: String, id: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.channel_passwords), NotificationManager.IMPORTANCE_DEFAULT))
        val update = Intent(context, UpdateReceiver::class.java).setAction(ACTION_UPDATE)
            .putExtra(EXTRA_SITE, site).putExtra(EXTRA_USERNAME, username).putExtra(EXTRA_PASSWORD, password).putExtra(EXTRA_UPDATE, id)
            .putExtra("identity", identity)
        val tap = PendingIntent.getBroadcast(context, identity.hashCode(), update, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.save_login_update_title, site))
            .setContentText(username)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, context.getString(R.string.save_login_update), tap).build())
            .setAutoCancel(true).build()
        manager.notify(identity, 0, notification)
    }

    class UpdateReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_UPDATE) return
            val site = intent.getStringExtra(EXTRA_SITE) ?: return
            val password = intent.getStringExtra(EXTRA_PASSWORD) ?: return
            val id = intent.getStringExtra(EXTRA_UPDATE) ?: return
            context.getSystemService(NotificationManager::class.java).cancel(intent.getStringExtra("identity"), 0)
            val tsync = Tsync.get(context)
            val pending = goAsync()
            tsync.scope.launch {
                try {
                    save(tsync, site, intent.getStringExtra(EXTRA_USERNAME).orEmpty(), password, update = id)
                } catch (e: Throwable) {
                    Log.w(Tsync.TAG, "update of a login failed", e)
                } finally {
                    pending.finish()
                }
            }
        }
    }
}
