package org.feverdreamtv.tsync.backup

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Ingest
import org.feverdreamtv.tsync.R

/**
 * One bounded pass over the camera roll, rescheduled while anything is still
 * owed.
 *
 * Partial progress is safe to abandon: each commit drains before it returns, and
 * anything a killed process left half-done is in the write-ahead log, which the
 * next invocation replays before it stages anything of its own.
 */
class BackupWorker(
    context: Context,
    parameters: WorkerParameters
) : CoroutineWorker(context, parameters) {

    companion object {
        const val TAG = "tsync-backup"

        /** Marks a run the user asked for, which the network and battery
         *  conditions set for background work do not gate. */
        const val USER_INITIATED = "userInitiated"
        private const val CHANNEL = "tsync-backup"
        private const val NOTIFICATION_ID = 2

        /** Staged bodies a crash left behind, which nothing else removes. */
        private const val ORPHAN_AGE_MS = 24L * 3600 * 1000

        private val running = java.util.concurrent.Semaphore(1)
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        // The watch trigger, the periodic job and the button are three unique
        // names, so WorkManager will run them together: two sweeps plan from the
        // same records and upload the same photo twice.
        if (!running.tryAcquire()) return@withContext Result.success()
        try {
            sweep()
        } finally {
            running.release()
        }
    }

    private suspend fun sweep(): Result {
        val prefs = BackupPrefs(applicationContext)
        if (!prefs.enabled) return Result.success()

        if (!MediaAccess.canRead(applicationContext)) {
            prefs.lastOutcome = "photo access not granted"
            return Result.success()
        }

        // A run the user asked for goes ahead on whatever network is there; only
        // the scheduled ones wait for the conditions they were given.
        if (!inputData.getBoolean(USER_INITIATED, false)) {
            NetworkGate.blockedBecause(applicationContext)?.let { blocked ->
                prefs.lastOutcome = blocked
                return Result.retry()
            }
        }

        promoteIfAllowed()
        Ingest.sweepOrphans(applicationContext, ORPHAN_AGE_MS)

        val records = UploadRecords(applicationContext)
        return try {
            val outcome =
                BackupSweep(
                    applicationContext,
                    records,
                    userInitiated = inputData.getBoolean(USER_INITIATED, false)
                ).execute { isStopped }
            prefs.lastOutcome = describe(outcome)
            prefs.settled = !outcome.more && outcome.failed == 0
            Log.i(TAG, "sweep: ${prefs.lastOutcome}")
            if (outcome.more) Result.retry() else Result.success()
        } catch (failure: Exception) {
            Log.w(TAG, "sweep failed: ${failure.message}")
            prefs.lastOutcome = "last sweep failed: ${failure.message}"
            Result.retry()
        } finally {
            records.close()
            // A content trigger fires once, so watching again is part of having
            // been woken by one.
            BackupSchedule.scheduleWatch(applicationContext)
        }
    }

    private fun describe(outcome: BackupSweep.Outcome): String = buildString {
        append("${outcome.uploaded} uploaded")
        if (outcome.failed > 0) append(", ${outcome.failed} failed")
        if (outcome.more) append(", more to do")
    }

    /**
     * A worker in the background may not be allowed to take the foreground at
     * all, so being refused means running the plain ten minutes rather than
     * failing the sweep.
     */
    private suspend fun promoteIfAllowed() {
        runCatching { setForeground(getForegroundInfo()) }
            .onFailure { Log.i(TAG, "staying in the background: ${it.message}") }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Camera backup", NotificationManager.IMPORTANCE_LOW)
        )
        val notification = Notification.Builder(applicationContext, CHANNEL)
            .setContentTitle("tsync")
            .setContentText("Backing up camera photos")
            .setSmallIcon(R.drawable.ic_notification)
            .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(
                NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }
}
