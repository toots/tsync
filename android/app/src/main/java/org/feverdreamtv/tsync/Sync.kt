package org.feverdreamtv.tsync

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/**
 * Learning what other clients wrote.
 *
 * Nothing runs between invocations to notice a foreign write, so the mirror is
 * refreshed on a schedule. A picker showing a domain that never changes is what
 * the absence of this looks like.
 */
class SyncWorker(
    context: Context,
    parameters: WorkerParameters
) : CoroutineWorker(context, parameters) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        if (!Config.exists(applicationContext)) return@withContext Result.success()
        val (code, output) = Tsync.plain(applicationContext, "sync")
        if (code == 0) {
            Result.success()
        } else {
            // Retried rather than failed: an unreachable server is the ordinary
            // reason, and the next run is the fix.
            Log.w(SyncSchedule.TAG, "sync exited $code\n${output.trim().takeLast(400)}")
            Result.retry()
        }
    }
}

object SyncSchedule {
    const val TAG = "tsync-sync"

    private const val PERIODIC = "mirror-sync-periodic"
    private const val NOW = "mirror-sync-now"

    /** Often enough that a domain does not look frozen, rarely enough to be
     *  invisible on a battery. Opening the app runs one immediately. */
    private const val PERIOD_HOURS = 6L

    private fun connected() =
        Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    fun enable(context: Context) {
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            PERIODIC,
            ExistingPeriodicWorkPolicy.UPDATE,
            PeriodicWorkRequestBuilder<SyncWorker>(PERIOD_HOURS, TimeUnit.HOURS)
                .setConstraints(connected())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .build()
        )
    }

    /** KEEP, not REPLACE: opening the app twice in a minute should not start a
     *  second walk over the same domain. */
    fun runNow(context: Context) {
        WorkManager.getInstance(context).enqueueUniqueWork(
            NOW,
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(connected())
                .build()
        )
    }
}
