package org.feverdreamtv.tsync.backup

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.Notifications
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Folders
import org.feverdreamtv.tsync.core.Naming
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.Target
import org.feverdreamtv.tsync.core.backup.BackupSettings
import org.feverdreamtv.tsync.core.backup.Device
import org.feverdreamtv.tsync.core.backup.DiscoveryPlanner
import org.feverdreamtv.tsync.core.backup.DiscoveryStart
import org.feverdreamtv.tsync.core.backup.Hold
import org.feverdreamtv.tsync.core.backup.MediaRow
import org.feverdreamtv.tsync.core.backup.PassOutcome
import org.feverdreamtv.tsync.core.backup.Processing
import org.feverdreamtv.tsync.core.backup.Record
import org.feverdreamtv.tsync.core.backup.State
import org.feverdreamtv.tsync.core.backup.Step
import java.time.ZoneId
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

/** The preferences file `camera-backup` (app §11.2). */
class BackupPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("camera-backup", Context.MODE_PRIVATE)

    var settings: BackupSettings
        get() = BackupSettings(
            enabled = prefs.getBoolean("enabled", false),
            unmeteredOnly = prefs.getBoolean("unmeteredOnly", true),
            whenBatteryOk = prefs.getBoolean("whenBatteryOk", true),
        )
        set(value) = prefs.edit().putBoolean("enabled", value.enabled).putBoolean("unmeteredOnly", value.unmeteredOnly)
            .putBoolean("whenBatteryOk", value.whenBatteryOk).apply()

    var lastOutcome: String?
        get() = prefs.getString("lastOutcome", null)
        set(value) = prefs.edit().putString("lastOutcome", value).apply()
}

/** One camera-backup pass (app §11.8) and what it is made of. */
class Backup(private val context: Context) {
    private val tsync = Tsync.get(context)
    private val db = RecordDb.get(context)
    private val media = MediaSource(context)
    val prefs = BackupPrefs(context)

    fun hold(): Hold? = Processing.gate(prefs.settings, device())

    private fun device(): Device {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = connectivity.activeNetwork?.let(connectivity::getNetworkCapabilities)
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100)?.takeIf { it > 0 } ?: 100
        return Device(
            networkPresent = capabilities != null,
            networkMetered = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true,
            charging = (battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0,
            batteryPercent = if (level < 0) 100 else level * 100 / scale,
        )
    }

    /** app §11.3, for every volume. A baseline pass records what exists as never to be uploaded. */
    fun discover(baseline: Boolean = false) {
        val now = System.currentTimeMillis()
        for (volume in media.volumes()) {
            val start = DiscoveryStart.of(db.mark(volume), media.version(volume), media.generation(volume), now)
            val full = start.full || baseline
            val planner = DiscoveryPlanner(volume, db.records(), start.copy(full = full), ZoneId.systemDefault(), now, baseline)
            media.rows(volume, start.mark.takeIf { !full }).forEach(planner::see)
            db.apply(volume, planner.changes(), planner.mark())
        }
    }

    /**
     * @return true when the pass must run again later
     */
    fun pass(userInitiated: Boolean, stopped: () -> Boolean): Boolean {
        if (!lock.tryLock()) return false
        try {
            if (!prefs.settings.enabled) return false
            if (media.access() == Access.DENIED) {
                prefs.lastOutcome = context.getString(R.string.backup_no_access)
                return false
            }
            if (!userInitiated) hold()?.let {
                prefs.lastOutcome = holdReason(context, it)
                return true
            }
            return try {
                check(tsync.boot() == Boot.Ready) { (tsync.boot as? Boot.Failed)?.reason ?: context.getString(R.string.provider_not_set_up) }
                tsync.ingest.intents.sweep()
                discover()
                val outcome = process(userInitiated, stopped)
                prefs.lastOutcome = describe(outcome)
                outcome.more || !Processing.settled(db.records())
            } catch (e: Exception) {
                Log.w(Tsync.TAG, "camera backup pass failed", e)
                prefs.lastOutcome = context.getString(R.string.backup_pass_failed, e.message ?: e.toString())
                true
            }
        } finally {
            lock.unlock()
        }
    }

    private fun describe(outcome: PassOutcome): String = listOfNotNull(
        context.getString(R.string.backup_uploaded, outcome.uploaded),
        outcome.failed.takeIf { it > 0 }?.let { context.getString(R.string.backup_failed, it) },
        context.getString(R.string.backup_more).takeIf { outcome.more },
    ).joinToString(", ")

    private fun process(userInitiated: Boolean, stopped: () -> Boolean): PassOutcome {
        val started = System.currentTimeMillis()
        val folders = Folders(tsync.client, db)
        var uploaded = 0
        var failed = 0
        var more = false
        for (record in Processing.due(db.records(), started)) {
            val now = System.currentTimeMillis()
            val row = media.row(record.volume, record.mediaId)
            if (row == null || Processing.step(row, now) != Step.UPLOAD) {
                if (row == null) db.delete(record.mediaId) else more = true
                continue
            }
            val staged = tsync.ask { status() }.pendingBytes
            val free = tsync.ingest.intents.stagingDirectory.usableSpace
            val gated = !userInitiated && hold() != null
            if (stopped() || gated || !Processing.withinBudget(staged, now - started, free, row.size)) {
                more = true
                break
            }
            try {
                db.put(upload(folders, record, row))
                uploaded++
            } catch (e: Exception) {
                db.put(Processing.failed(record, e.message ?: e.toString(), System.currentTimeMillis()))
                failed++
            }
        }
        return PassOutcome(uploaded, failed, more)
    }

    private fun upload(folders: Folders, record: Record, row: MediaRow): Record {
        val directory = Naming.parentPath(record.target)
        val firstUpload = record.etag == null
        val folder = folders.folderFor(directory)
        val ingest = tsync.ingest
        // The intent stays open: the media store keeps the photo, so a failed or interrupted
        // commit drops the staged copy and the record retries.
        val name = ingest.stage(Target.Child(folder, Naming.leaf(record.target)), firstUpload, Processing.base(record), row.captureMillis)
        try {
            val copied = media.open(record.volume, row).use { input -> ingest.staging(name).outputStream().use(input::copyTo) }
            if (copied != row.size) throw java.io.IOException("copied $copied bytes of ${row.size}")
        } catch (e: Exception) {
            ingest.abandon(name)
            throw e
        }
        val item = try {
            // Another device's photo holds the name: the next sequence name no record claims.
            ingest.commit(name, reroute = false, candidates = { leaf ->
                Naming.candidates(leaf).filter { it == leaf || !db.targetTaken("$directory/$it") }
            }).item
        } catch (e: CoreException) {
            if (e.code == Code.NOT_FOUND) folders.forget(directory)
            throw e
        }
        return Processing.uploaded(record, row, "$directory/${item.name}", item.contentId ?: item.etag, System.currentTimeMillis())
    }

    /** `off | <n> failed — <last error> | not started yet | <n> waiting to upload | up to date`, and what qualifies it. */
    fun statusLine(): String {
        val settings = prefs.settings
        if (!settings.enabled) return context.getString(R.string.backup_off)
        val records = db.records()
        val failed = records.filter { it.state == State.FAILED }
        val waiting = records.count { it.state == State.PENDING }
        val main = when {
            failed.isNotEmpty() -> context.getString(R.string.backup_status_failed, failed.size, failed.maxBy { it.updatedAt }.lastError.orEmpty())
            prefs.lastOutcome == null && records.isEmpty() -> context.getString(R.string.backup_not_started)
            waiting > 0 -> context.resources.getQuantityString(R.plurals.backup_waiting, waiting, waiting)
            else -> context.getString(R.string.backup_up_to_date)
        }
        return listOfNotNull(
            main,
            hold()?.let { holdReason(context, it) },
            context.getString(R.string.backup_selected_only).takeIf { media.access() == Access.SELECTED },
            prefs.lastOutcome,
        ).joinToString(" · ")
    }

    fun access(): Access = media.access()

    companion object {
        private val lock = ReentrantLock()

        fun holdReason(context: Context, hold: Hold): String =
            context.getString(if (hold == Hold.WIFI) R.string.backup_waiting_wifi else R.string.backup_battery_low)
    }
}

class BackupWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun getForegroundInfo(): ForegroundInfo {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        return ForegroundInfo(Notifications.BACKUP_ID, Notifications.backupRunning(applicationContext), type)
    }

    override fun doWork(): Result {
        val userInitiated = inputData.getBoolean(USER_INITIATED, false)
        try {
            setForegroundAsync(getForegroundInfo()).get()
        } catch (e: Exception) {
            // A refusal to go foreground does not stop the pass.
            Log.w(Tsync.TAG, "camera backup runs in the background", e)
        }
        val backup = Backup(applicationContext)
        try {
            return if (backup.pass(userInitiated, ::isStopped)) Result.retry() else Result.success()
        } finally {
            // A content trigger fires once, so the run it started enqueues the next: appended, since
            // replacing would cancel this very run. Any other run finds the trigger still enqueued.
            if (backup.prefs.settings.enabled) {
                val policy = if (BackupSchedule.ON_CHANGES in tags) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.KEEP
                BackupSchedule.onMediaChanges(applicationContext, backup.prefs.settings, policy)
            }
        }
    }

    companion object {
        const val USER_INITIATED = "userInitiated"
    }
}

/** The three unique jobs of app §11.6. */
object BackupSchedule {
    const val ON_CHANGES = "camera-backup-changes"
    private const val PERIODIC = "camera-backup-periodic"
    private const val NOW = "camera-backup-now"

    private fun constraints(settings: BackupSettings): Constraints.Builder = Constraints.Builder()
        .setRequiredNetworkType(if (settings.unmeteredOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(settings.whenBatteryOk)
        .setRequiresStorageNotLow(true)

    fun onMediaChanges(context: Context, settings: BackupSettings, policy: ExistingWorkPolicy = ExistingWorkPolicy.REPLACE) {
        val constraints = constraints(settings)
            .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
            .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
            .setTriggerContentUpdateDelay(Parameters.TRIGGER_DELAY_S, TimeUnit.SECONDS)
            .setTriggerContentMaxDelay(Parameters.TRIGGER_MAX_DELAY_S, TimeUnit.SECONDS)
            .build()
        val request = OneTimeWorkRequest.Builder(BackupWorker::class.java).setConstraints(constraints).addTag(ON_CHANGES).build()
        WorkManager.getInstance(context).enqueueUniqueWork(ON_CHANGES, policy, request)
    }

    /** Enqueues with the settings' constraints; a changed setting replaces what was enqueued. */
    fun schedule(context: Context, settings: BackupSettings) {
        onMediaChanges(context, settings)
        val periodic = PeriodicWorkRequest.Builder(BackupWorker::class.java, Parameters.PERIODIC_INTERVAL_H, TimeUnit.HOURS)
            .setConstraints(constraints(settings).build()).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, periodic)
    }

    fun runNow(context: Context) {
        val request = OneTimeWorkRequest.Builder(BackupWorker::class.java)
            .setInputData(Data.Builder().putBoolean(BackupWorker.USER_INITIATED, true).build())
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST).build()
        WorkManager.getInstance(context).enqueueUniqueWork(NOW, ExistingWorkPolicy.KEEP, request)
    }

    fun cancel(context: Context) {
        val work = WorkManager.getInstance(context)
        listOf(ON_CHANGES, PERIODIC, NOW).forEach(work::cancelUniqueWork)
    }
}
