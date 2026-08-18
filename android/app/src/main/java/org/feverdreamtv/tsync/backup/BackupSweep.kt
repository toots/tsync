package org.feverdreamtv.tsync.backup

import android.content.Context
import android.net.Uri
import android.util.Log
import org.feverdreamtv.tsync.Config
import org.feverdreamtv.tsync.Daemon
import org.feverdreamtv.tsync.Ingest
import org.feverdreamtv.tsync.Keys
import java.io.File
import java.io.FileOutputStream
import java.time.ZoneId

/**
 * One pass over the camera roll.
 *
 * Bounded rather than exhaustive: a staged body sits in app-private storage
 * until its upload publishes, and maxCache does not cover those — enforce_cap
 * sweeps the chunk directory only (lib/content/chunk_cache.ml). An unbounded
 * first backfill would fill the device.
 */
class BackupSweep(
    private val context: Context,
    private val records: UploadRecords,
    private val zone: ZoneId = ZoneId.systemDefault()
) {
    companion object {
        const val TAG = "tsync-backup"

        /** Staged but not yet published, across the whole sweep. */
        const val STAGED_BYTES_BUDGET = 512L * 1024 * 1024
        const val QUEUE_DEPTH_LIMIT = 32

        /** A platform job is stopped around ten minutes in; leave room to record
         *  what was done rather than being killed mid-write. */
        const val TIME_BUDGET_MILLIS = 8L * 60 * 1000

        /** Headroom over the file itself, since the daemon's rename lands the
         *  body on this same filesystem. */
        const val FREE_SPACE_FACTOR = 2

        const val LOOKBACK_SECONDS = 24L * 3600
        private const val COPY_BUFFER = 1 shl 16
    }

    data class Outcome(val uploaded: Int, val skipped: Int, val failed: Int, val more: Boolean)

    /** Answers false when the sweep should stop early, so the caller reschedules
     *  rather than treating a truncated pass as a finished one. */
    fun interface Cancelled {
        fun check(): Boolean
    }

    fun execute(cancelled: Cancelled): Outcome {
        val domain = Config.load(context)?.domain ?: return Outcome(0, 0, 0, more = false)
        val socket = Daemon.socket(context)
        val root = Keys.root(domain)
        val knownDirs = records.knownDirs()

        var uploaded = 0
        var skipped = 0
        var failed = 0
        var stagedBytes = 0L
        var more = false
        val startedAt = System.currentTimeMillis()

        for (volume in MediaScan.volumes(context)) {
            val watermark = records.watermark(volume)
            val generation = MediaScan.currentGeneration(context, volume)
            var highestDateAdded = watermark.dateAddedSeconds

            for (collection in MediaScan.collections(volume)) {
                val rows = MediaScan.query(
                    context, volume, collection, watermark, LOOKBACK_SECONDS
                )
                val plan = BackupPlanner.plan(
                    rows, records.all(), System.currentTimeMillis(), zone
                )

                for (action in plan) {
                    if (cancelled.check() ||
                        stagedBytes >= STAGED_BYTES_BUDGET ||
                        System.currentTimeMillis() - startedAt >= TIME_BUDGET_MILLIS
                    ) {
                        // The folders made so far are made whether or not this
                        // pass finished, and re-stat'ing them costs the daemon a
                        // lookup each.
                        records.rememberDirs(knownDirs)
                        return Outcome(uploaded, skipped, failed, more = true)
                    }

                    when (action) {
                        is BackupAction.Skip -> {
                            skipped++
                            when (action.reason) {
                                // Only a settled row may advance the watermark,
                                // or a capture still being written is never
                                // looked at again.
                                SkipReason.ALREADY_DONE -> highestDateAdded =
                                    BackupPlanner.advanceWatermark(
                                        highestDateAdded, action.row
                                    )

                                // Worth another pass, once the bytes are there.
                                SkipReason.STILL_PENDING, SkipReason.UNSETTLED -> more = true

                                // A row with no bytes and nothing pending will
                                // not improve, and asking again forever would
                                // keep the sweep rescheduling itself.
                                SkipReason.EMPTY -> Unit
                            }
                        }

                        is BackupAction.Upload -> {
                            waitForQueue(cancelled)
                            val outcome = upload(socket, root, action, knownDirs, collection, volume)
                            if (outcome) {
                                uploaded++
                                stagedBytes += action.row.sizeBytes
                                highestDateAdded =
                                    BackupPlanner.advanceWatermark(
                                        highestDateAdded, action.row
                                    )
                            } else {
                                failed++
                            }
                        }
                    }
                }
            }

            records.setWatermark(volume, Watermark(generation, highestDateAdded))
        }

        records.rememberDirs(knownDirs)
        return Outcome(uploaded, skipped, failed, more)
    }

    /** Lets the daemon's queue drain before handing it more, the staged bodies
     *  being what occupies the disk until each upload publishes. */
    private fun waitForQueue(cancelled: Cancelled) {
        repeat(120) {
            if (cancelled.check()) return
            val status = runCatching { Daemon.status(context) }.getOrNull() ?: return
            if (Daemon.pendingUploads(status) < QUEUE_DEPTH_LIMIT &&
                Daemon.pendingBytes(status) < STAGED_BYTES_BUDGET
            ) {
                return
            }
            Thread.sleep(1_000)
        }
    }

    private fun upload(
        socket: File,
        root: String,
        action: BackupAction.Upload,
        knownDirs: MutableSet<String>,
        collection: MediaScan.Collection,
        volume: String
    ): Boolean {
        val row = action.row
        val key = root + action.relativePath
        val staging = Ingest.newStaging(context)
        return try {
            // The staging file is a name that nothing has created yet, and
            // usableSpace answers 0 for a path that does not exist, so this asks
            // the directory holding it instead.
            if (staging.parentFile.usableSpace < row.sizeBytes * FREE_SPACE_FACTOR) {
                throw IllegalStateException("not enough free space for ${row.displayName}")
            }
            // The folder has to exist before the file lands in it: an upload
            // mints a folder id but writes no Mkdir entry, leaving the tree
            // unlistable (ipc_handler.ml handle_list_dir).
            Ingest.ensureDirs(socket, root, key, knownDirs)

            val uri = MediaScan.originalUri(MediaScan.contentUri(collection, row.mediaId))
            val copied = copy(uri, staging)
            if (copied != row.sizeBytes) {
                throw IllegalStateException(
                    "${row.displayName}: copied $copied of ${row.sizeBytes} bytes"
                )
            }

            Ingest.commit(socket, key, staging, modified = row.captureMillis)
            records.put(
                UploadRecord(
                    row.mediaId, action.relativePath, row.sizeBytes,
                    row.modifiedSeconds, UploadState.DONE
                ),
                volume
            )
            true
        } catch (failure: Exception) {
            staging.delete()
            Log.w(TAG, "backup ${row.displayName}: ${failure.message}")
            records.put(
                UploadRecord(
                    row.mediaId, action.relativePath, row.sizeBytes,
                    row.modifiedSeconds, UploadState.FAILED
                ),
                volume, failure.message
            )
            false
        }
    }

    private fun copy(uri: Uri, staging: File): Long {
        var total = 0L
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "no stream for $uri" }
            FileOutputStream(staging).use { output ->
                val buffer = ByteArray(COPY_BUFFER)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    total += read
                }
            }
        }
        return total
    }
}
