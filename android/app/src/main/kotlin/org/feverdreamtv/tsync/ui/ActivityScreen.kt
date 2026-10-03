package org.feverdreamtv.tsync.ui

import android.text.format.Formatter
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Notifications
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.backup.Backup
import org.feverdreamtv.tsync.backup.BackupSchedule
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.KeepAliveCounter.Work
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.PendingSave
import org.feverdreamtv.tsync.core.Stats
import org.feverdreamtv.tsync.core.Status

private data class Snapshot(
    val status: Status?,
    val stats: Stats?,
    val failure: String?,
    val saves: List<PendingSave>,
    val backup: String,
    val backupEnabled: Boolean,
    val details: String,
)

private fun snapshot(tsync: Tsync): Snapshot {
    val status = runCatching { tsync.ask { status() } }
    val backup = Backup(tsync.context)
    return Snapshot(
        status = status.getOrNull(),
        stats = runCatching { tsync.client.stats() }.getOrNull(),
        failure = status.exceptionOrNull()?.message,
        saves = tsync.ingest.pending(),
        backup = backup.statusLine(),
        backupEnabled = backup.prefs.settings.enabled,
        details = runCatching { tsync.core.status() }.getOrElse { it.message.orEmpty() },
    )
}

/** What the app is doing and what went wrong (app §10.5), polled only while visible. */
@Composable
fun ActivityScreen(tsync: Tsync, outer: PaddingValues) {
    val context = LocalContext.current
    var visible by remember { mutableStateOf(false) }
    var shown by remember { mutableStateOf<Snapshot?>(null) }
    val offline by tsync.offline.collectAsState()
    LifecycleResumeEffect(Unit) {
        visible = true
        onPauseOrDispose { visible = false }
    }
    LaunchedEffect(visible) {
        while (visible) {
            shown = withContext(Dispatchers.IO) { snapshot(tsync) }
            delay(Parameters.STATUS_POLL_MS)
        }
    }

    fun run(work: () -> String) {
        tsync.scope.launch {
            try {
                tsync.report(work())
            } catch (e: CoreException) {
                tsync.report(e.message ?: e.code.wire, failed = true)
            }
        }
    }

    Screen(stringResource(R.string.destination_activity), outer) { padding ->
        val state = shown
        if (state == null) {
            Loading(padding)
            return@Screen
        }
        val status = state.status
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp)) {
            val line = when {
                status == null -> state.failure ?: stringResource(R.string.state_unknown)
                offline -> stringResource(R.string.state_offline)
                status.paused -> stringResource(R.string.state_paused)
                status.readOnly -> stringResource(R.string.state_read_only)
                else -> stringResource(R.string.state_connected)
            }
            Text(line, style = MaterialTheme.typography.titleLarge)
            if (status != null) {
                OutlinedButton(onClick = { run { tsync.ask { pause(!status.paused) }; context.getString(if (status.paused) R.string.resumed else R.string.paused) } }) {
                    Text(stringResource(if (status.paused) R.string.resume else R.string.pause))
                }

                Section(R.string.uploads)
                status.uploading.forEach { Text(it.name) }
                val waiting = (status.pendingUploads - status.uploading.size).coerceAtLeast(0)
                Text(pluralStringResource(R.plurals.uploads_waiting, waiting, waiting, Formatter.formatFileSize(context, status.pendingBytes)))

                Section(R.string.downloads)
                if (status.downloading.isEmpty()) Text(stringResource(R.string.no_downloads))
                status.downloading.forEach { download ->
                    Text(download.name)
                    LinearProgressIndicator(
                        progress = { if (download.size > 0) download.bytes.toFloat() / download.size else 0f },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        stringResource(
                            R.string.download_progress,
                            Formatter.formatFileSize(context, download.bytes),
                            Formatter.formatFileSize(context, download.size),
                            Formatter.formatFileSize(context, download.rate.toLong()),
                        ),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }

            Section(R.string.problems)
            val parked = state.stats?.parked ?: 0
            if (state.saves.isEmpty() && parked == 0) Text(stringResource(R.string.no_problems))
            for (save in state.saves) Row(verticalAlignment = Alignment.CenterVertically) {
                val intent = save.intent
                Text(
                    if (intent != null) stringResource(R.string.save_failed_title, intent.target.name) else stringResource(R.string.save_unreadable_text, save.staging),
                    Modifier.weight(1f),
                )
                if (intent != null) TextButton(onClick = {
                    tsync.scope.launch {
                        tsync.keepAlive.retain(Work.SAVE)
                        try {
                            val result = runCatching { tsync.ingest.retry(save.staging) ?: return@launch }
                            Notifications.saveOutcome(tsync, save.staging, intent.target.name, result)
                            result.onSuccess { tsync.report(context.getString(R.string.saved_as, it.item.name)) }
                                .onFailure { tsync.report(it.message ?: it.toString(), failed = true) }
                        } finally {
                            tsync.keepAlive.release(Work.SAVE)
                        }
                    }
                }) { Text(stringResource(R.string.retry)) }
            }
            if (parked > 0) Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    pluralStringResource(R.plurals.parked_changes, parked, parked) + state.stats?.lastError?.let { ": $it" }.orEmpty(),
                    Modifier.weight(1f),
                )
                TextButton(onClick = { run { tsync.ask { retry() }.let { context.resources.getQuantityString(R.plurals.retried_changes, it, it) } } }) {
                    Text(stringResource(R.string.retry_now))
                }
            }

            Section(R.string.camera_backup)
            Text(state.backup)
            if (state.backupEnabled) Button(onClick = { BackupSchedule.runNow(context) }, modifier = Modifier.padding(top = 8.dp)) {
                Text(stringResource(R.string.back_up_now))
            }

            Section(R.string.details)
            SelectionContainer { Text(state.details, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
fun Section(title: Int) {
    Text(
        stringResource(title),
        Modifier.padding(top = 24.dp, bottom = 8.dp).semantics { heading() },
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.primary,
    )
}
