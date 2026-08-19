package org.feverdreamtv.tsync.backup

import android.content.Context
import android.os.Build
import android.provider.MediaStore
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit

/**
 * When a sweep runs.
 *
 * The camera roll is watched through a content-URI trigger rather than a
 * ContentObserver: an observer is registered by a live process, and the case
 * that needs covering is precisely the one where the process is gone. The
 * periodic sweep stays because a trigger is cancelled by force-stop and deferred
 * in Doze.
 */
object BackupSchedule {

    private const val WATCH = "camera-backup-watch"
    private const val PERIODIC = "camera-backup-periodic"
    private const val NOW = "camera-backup-now"

    private const val PERIOD_HOURS = 6L

    /** Coalesces a burst of shots into one run instead of one run per frame. */
    private const val TRIGGER_DELAY_SECONDS = 10L
    private const val TRIGGER_MAX_DELAY_SECONDS = 300L

    fun enable(context: Context) {
        scheduleWatch(context)
        schedulePeriodic(context)
    }

    fun disable(context: Context) {
        val work = WorkManager.getInstance(context)
        listOf(WATCH, PERIODIC, NOW).forEach { work.cancelUniqueWork(it) }
    }

    /**
     * Moves each volume's watermark past everything already on the phone, so
     * only captures made from here on are owed.
     *
     * Taken from the newest row rather than the clock: the watermark is cut
     * against DATE_ADDED, which MediaStore assigns, and a device whose clock
     * disagrees with it would skip the difference.
     */
    fun skipExistingRoll(context: Context) {
        val records = UploadRecords(context)
        try {
            MediaScan.volumes(context).forEach { volume ->
                records.setWatermark(
                    volume,
                    Watermark(
                        MediaScan.currentGeneration(context, volume),
                        MediaScan.newestAdded(context, volume)
                    )
                )
            }
        } finally {
            records.close()
        }
    }

    /** Re-enqueued at the end of every run: a content trigger fires once. */
    fun scheduleWatch(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val constraints = constraints(context)
            .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
            .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
            .setTriggerContentUpdateDelay(TRIGGER_DELAY_SECONDS, TimeUnit.SECONDS)
            .setTriggerContentMaxDelay(TRIGGER_MAX_DELAY_SECONDS, TimeUnit.SECONDS)
            .build()

        WorkManager.getInstance(context).enqueueUniqueWork(
            WATCH,
            ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<BackupWorker>()
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.MINUTES)
                .build()
        )
    }

    fun schedulePeriodic(context: Context) {
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            PERIODIC,
            ExistingPeriodicWorkPolicy.UPDATE,
            PeriodicWorkRequestBuilder<BackupWorker>(PERIOD_HOURS, TimeUnit.HOURS)
                .setConstraints(constraints(context).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
                .build()
        )
    }

    /** The user asked, so the constraints they set for background work do not
     *  apply — which the worker has to be told, or it holds the run back for the
     *  same conditions. */
    fun runNow(context: Context) {
        WorkManager.getInstance(context).enqueueUniqueWork(
            NOW,
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<BackupWorker>()
                .setInputData(workDataOf(BackupWorker.USER_INITIATED to true))
                .build()
        )
    }

    private fun constraints(context: Context): Constraints.Builder {
        val prefs = BackupPrefs(context)
        return Constraints.Builder()
            .setRequiredNetworkType(
                if (prefs.unmeteredOnly) NetworkType.UNMETERED else NetworkType.CONNECTED
            )
            .setRequiresBatteryNotLow(prefs.whenBatteryOk)
            // A staged body occupies the same filesystem the daemon caches into.
            .setRequiresStorageNotLow(true)
    }
}
