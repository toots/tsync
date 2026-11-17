package org.feverdreamtv.tsync.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.Notifications
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Served
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.backup.Backup
import org.feverdreamtv.tsync.backup.BackupSchedule
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.KeepAliveCounter.Work
import org.feverdreamtv.tsync.core.LogLine
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.PendingSave
import org.feverdreamtv.tsync.core.Stats
import org.feverdreamtv.tsync.core.Status
import org.feverdreamtv.tsync.core.StoreReport

/** activity §2.3: at most this many warnings before Show all. */
private const val SHOWN_ERRORS = 5

/** One domain as last asked; [status] and the rest are null for a domain not booted, which is asked nothing. */
private class DomainSnapshot(
    val domain: Served,
    val booted: Boolean,
    val status: Status?,
    val stats: Stats?,
    val failure: String?,
    val offline: Boolean,
)

private data class Snapshot(
    val domains: List<DomainSnapshot>,
    val saves: List<PendingSave>,
    val backup: String,
    val backupEnabled: Boolean,
)

/** activity §1: domains are asked concurrently, so a slow one delays no other. */
private suspend fun snapshot(tsync: Tsync): Snapshot = coroutineScope {
    val backup = Backup(tsync.context)
    Snapshot(
        domains = tsync.domains().map { domain -> async { ask(domain) } }.awaitAll(),
        saves = tsync.ingest.pending(),
        backup = backup.statusLine(),
        backupEnabled = backup.prefs.settings.enabled,
    )
}

private fun ask(domain: Served): DomainSnapshot {
    if (domain.boot != Boot.Ready) return DomainSnapshot(domain, false, null, null, null, false)
    val status = runCatching { domain.ask { status() } }
    val stats = runCatching { domain.ask { stats() } }.getOrNull()
    // activity §1: a domain the reply lists unanswered did not answer.
    if (stats?.unanswered == true) return DomainSnapshot(domain, true, null, null, "no process reported it", domain.offline.value)
    return DomainSnapshot(
        domain = domain,
        booted = true,
        status = status.getOrNull(),
        stats = stats,
        failure = status.exceptionOrNull()?.message,
        offline = domain.offline.value,
    )
}

private enum class Tone { NEUTRAL, GOOD, WARNING, FAILURE }

private class State(val badge: Int, val sentence: String?, val tone: Tone)

/** activity §2.1: the first state that holds. */
@Composable
private fun state(status: Status, stats: Stats?, offline: Boolean): State {
    val failing = status.failing ?: stats?.syncFailing
    val stuck = stats?.cannotFollow
    val pending = status.pendingUploads + status.pendingDownloads + (stats?.syncPending ?: 0)
    return when {
        status.paused -> State(R.string.state_paused, stringResource(R.string.activity_paused_text), Tone.WARNING)
        failing != null -> State(R.string.activity_not_syncing, stringResource(R.string.activity_retried, failing), Tone.FAILURE)
        stuck != null -> State(R.string.activity_not_syncing, stringResource(R.string.activity_cannot_follow, stuck.entry, stuck.reason), Tone.FAILURE)
        offline || stats?.mainOffline == true -> State(R.string.activity_store_offline, stringResource(R.string.activity_store_offline_text), Tone.WARNING)
        status.readOnly -> State(R.string.state_read_only, stringResource(R.string.activity_read_only_text), Tone.WARNING)
        pending > 0 -> State(
            R.string.activity_syncing,
            listOfNotNull(
                status.pendingUploads.takeIf { it > 0 }?.let { pluralStringResource(R.plurals.activity_to_upload, it, it) },
                status.pendingDownloads.takeIf { it > 0 }?.let { pluralStringResource(R.plurals.activity_to_download, it, it) },
            ).joinToString(", "),
            Tone.NEUTRAL,
        )
        else -> State(R.string.activity_up_to_date, null, Tone.GOOD)
    }
}

/** What the app is doing and what went wrong (activity.md), per booted domain, polled only while visible. */
@Composable
fun ActivityScreen(tsync: Tsync, outer: PaddingValues) {
    val context = LocalContext.current
    var visible by remember { mutableStateOf(false) }
    var shown by remember { mutableStateOf<Snapshot?>(null) }
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
        val several = state.domains.size > 1
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp)) {
            for (entry in state.domains) {
                if (several) Text(entry.domain.name, Modifier.padding(top = 16.dp).semantics { heading() }, style = MaterialTheme.typography.headlineSmall)
                DomainActivity(entry, ::run)
            }

            // activity §3: the app's and the process's, not a domain's.
            if (state.saves.isNotEmpty()) {
                Section(R.string.activity_failed_saves)
                FailedSaves(tsync, state.saves)
            }
            Warnings(state.domains.flatMap { it.stats?.recentErrors.orEmpty() })

            Section(R.string.camera_backup)
            Text(state.backup)
            if (state.backupEnabled) Button(onClick = { BackupSchedule.runNow(context) }, modifier = Modifier.padding(top = 8.dp)) {
                Text(stringResource(R.string.back_up_now))
            }
        }
    }
}

@Composable
private fun DomainActivity(entry: DomainSnapshot, run: (() -> String) -> Unit) {
    val context = LocalContext.current
    val domain = entry.domain
    if (!entry.booted) {
        Text(stringResource(R.string.domain_not_booted))
        return
    }
    val status = entry.status
    if (status == null) {
        Text(stringResource(R.string.activity_not_answering, entry.failure ?: stringResource(R.string.state_unknown)))
        return
    }
    val stats = entry.stats
    val current = state(status, stats, entry.offline)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Badge(stringResource(current.badge), current.tone)
            current.sentence?.takeIf { it.isNotEmpty() }?.let { Text(it, Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodyMedium) }
        }
        OutlinedButton(onClick = { run { domain.ask { pause(!status.paused) }; context.getString(if (status.paused) R.string.resumed else R.string.paused) } }) {
            Text(stringResource(if (status.paused) R.string.resume else R.string.pause))
        }
    }

    Section(R.string.activity_transfers)
    val waiting = (status.pendingUploads - status.uploading.size).coerceAtLeast(0)
    status.uploading.forEach { Transfer("↑ " + it.name, it.bytes, it.size ?: 0, it.rate) }
    if (waiting > 0) Text(
        if (status.pendingBytes > 0) pluralStringResource(R.plurals.uploads_waiting, waiting, waiting, size(status.pendingBytes))
        else pluralStringResource(R.plurals.activity_more_waiting, waiting, waiting),
        style = MaterialTheme.typography.bodySmall,
    )
    status.downloading.forEach { Transfer("↓ " + it.name, it.bytes, it.size, it.rate) }
    if (status.uploading.isEmpty() && status.downloading.isEmpty() && waiting == 0 && status.pendingDownloads == 0) {
        Text(stringResource(R.string.activity_nothing_to_transfer))
    }

    Section(R.string.problems)
    Problems(stats, run, domain)

    val stores = stats?.stores.orEmpty()
    if (stores.isNotEmpty()) {
        Section(R.string.activity_stores)
        stores.forEach { StoreCard(it) }
    }

    Section(R.string.activity_this_device)
    val cache = stats?.cacheBytes ?: 0
    val limit = stats?.maxCache
    if (limit != null && limit > 0) Meter(stringResource(R.string.activity_cache), stringResource(R.string.activity_cache_value, size(cache), size(limit)), cache, limit)
    else Text(stringResource(R.string.activity_cache) + ": " + size(cache))
    stats?.pinnedBytes?.takeIf { it > 0 }?.let { Text(stringResource(R.string.activity_kept_offline, size(it)), style = MaterialTheme.typography.bodySmall) }
    stats?.ownRam?.let { Text(stringResource(R.string.activity_memory, size(it)), style = MaterialTheme.typography.labelSmall) }

    Details(status, stats)
}

@Composable
private fun Problems(stats: Stats?, run: (() -> String) -> Unit, domain: Served) {
    val context = LocalContext.current
    val parked = stats?.parked ?: 0
    val setAside = stats?.setAside ?: 0
    val stores = stats?.stores.orEmpty().filter { it.hasProblem }
    if (parked > 0) Row(verticalAlignment = Alignment.CenterVertically) {
        Problem(pluralStringResource(R.plurals.activity_parked, parked, parked), stats?.lastError, Modifier.weight(1f))
        TextButton(onClick = { run { domain.ask { retry() }.let { context.resources.getQuantityString(R.plurals.retried_changes, it, it) } } }) {
            Text(stringResource(R.string.retry_now))
        }
    }
    if (setAside > 0) Problem(pluralStringResource(R.plurals.activity_set_aside, setAside, setAside), stringResource(R.string.activity_set_aside_text))
    stores.forEach { Problem(it.name, if (it.damagedChunks > 0 && !it.down && it.reachable != false) damaged(it) else connection(it)) }
    if (parked == 0 && setAside == 0 && stores.isEmpty()) Text(stringResource(R.string.no_problems))
}

@Composable
private fun FailedSaves(tsync: Tsync, saves: List<PendingSave>) {
    val context = LocalContext.current
    for (save in saves) Row(verticalAlignment = Alignment.CenterVertically) {
        val intent = save.intent
        Problem(
            if (intent != null) stringResource(R.string.save_failed_title, intent.target.name) else stringResource(R.string.save_unreadable_text, save.staging),
            null,
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
}

/** activity §3: the processes' warnings and errors, once, newest first. */
@Composable
private fun Warnings(lines: List<LogLine>) {
    var all by rememberSaveable { mutableStateOf(false) }
    val errors = lines.filter { it.level == "warn" || it.level == "err" }.distinctBy { it.time to it.message }.sortedByDescending { it.time }
    if (errors.isEmpty()) return
    Section(R.string.activity_warnings)
    (if (all) errors else errors.take(SHOWN_ERRORS)).forEach { ErrorLine(it) }
    if (errors.size > SHOWN_ERRORS) TextButton(onClick = { all = !all }) {
        Text(if (all) stringResource(R.string.activity_show_fewer) else stringResource(R.string.activity_show_all, errors.size))
    }
}

@Composable
private fun Badge(text: String, tone: Tone) {
    val color = when (tone) {
        Tone.GOOD -> Color(0xFF2E7D32)
        Tone.NEUTRAL -> MaterialTheme.colorScheme.primary
        Tone.WARNING -> Color(0xFFE65100)
        Tone.FAILURE -> MaterialTheme.colorScheme.error
    }
    Surface(shape = CircleShape, color = color.copy(alpha = 0.15f)) {
        Text(text, Modifier.padding(horizontal = 12.dp, vertical = 4.dp), color = color, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Transfer(name: String, bytes: Long, total: Long, rate: Double) {
    Column(Modifier.padding(vertical = 4.dp)) {
        Text(name, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
        if (total > 0) {
            LinearProgressIndicator(progress = { (bytes.toFloat() / total).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp))
            Text(stringResource(R.string.download_progress, size(bytes), size(total), size(rate.toLong())), style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun Problem(text: String, detail: String?, modifier: Modifier = Modifier) {
    Column(modifier.padding(vertical = 4.dp)) {
        Text("⚠ $text")
        detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun ErrorLine(line: LogLine) {
    Column(Modifier.padding(vertical = 4.dp)) {
        Text((if (line.level == "err") "⛔ " else "⚠ ") + line.message, style = MaterialTheme.typography.bodySmall)
        Text(
            DateUtils.getRelativeTimeSpanString((line.time * 1000).toLong()).toString(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** activity §2.4. */
@Composable
private fun StoreCard(store: StoreReport) {
    ElevatedCard(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(store.name, style = MaterialTheme.typography.titleMedium)
                store.role?.takeIf { it != store.name }?.let {
                    Spacer(Modifier.width(8.dp))
                    Text(it.replaceFirstChar(Char::uppercase), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.weight(1f))
                Text(if (store.hasProblem) "⚠" else "✓", color = if (store.hasProblem) Color(0xFFE65100) else Color(0xFF2E7D32))
            }
            Text(connection(store), style = MaterialTheme.typography.bodySmall, color = if (store.down || store.reachable == false) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            val free = store.freeBytes
            val total = store.totalBytes
            if (free != null && total != null && total > 0) Meter(stringResource(R.string.activity_space), stringResource(R.string.activity_space_value, size(free), size(total)), total - free, total)
            if (store.copiesOwed > 0) {
                Text(
                    pluralStringResource(R.plurals.activity_to_copy, store.copiesOwed, store.copiesOwed) +
                        if (store.copiesRate > 0) ", " + stringResource(R.string.activity_copy_rate, store.copiesRate) else "",
                    style = MaterialTheme.typography.bodySmall,
                )
                store.copying?.takeIf { store.copyChunks > 0 }?.let {
                    Text(it, maxLines = 1, overflow = TextOverflow.MiddleEllipsis, style = MaterialTheme.typography.labelSmall)
                    LinearProgressIndicator(progress = { (store.copyChecked.toFloat() / store.copyChunks).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                }
            }
            if (store.damagedChunks > 0) Text(damaged(store), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
}

/** A labelled bar of a part against its whole. */
@Composable
private fun Meter(label: String, value: String, used: Long, total: Long) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row {
            Text(label, style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.weight(1f))
            Text(value, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        val part = (used.toFloat() / total).coerceIn(0f, 1f)
        LinearProgressIndicator(
            progress = { part },
            modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
            color = if (part > 0.9f) Color(0xFFE65100) else MaterialTheme.colorScheme.primary,
        )
    }
}

/** activity §2.6: the settings in force; the replies only as Copy report. */
@Composable
private fun Details(status: Status, stats: Stats?) {
    val context = LocalContext.current
    var open by rememberSaveable(status.domain) { mutableStateOf(false) }
    TextButton(onClick = { open = !open }, modifier = Modifier.padding(top = 8.dp)) { Text(stringResource(R.string.details)) }
    if (!open) return
    Text(stringResource(R.string.activity_settings_in_force), style = MaterialTheme.typography.titleSmall)
    fun onOff(value: Boolean?) = context.getString(if (value == true) R.string.activity_on else R.string.activity_off)
    Setting(stringResource(R.string.activity_versioning), onOff(stats?.versioning))
    Setting(stringResource(R.string.state_read_only), onOff(stats?.readOnly))
    stats?.symlinks?.let { Setting(stringResource(R.string.activity_symlinks), it.replaceFirstChar(Char::uppercase)) }
    stats?.chunkSize?.let { Setting(stringResource(R.string.activity_chunk_size), size(it)) }
    Setting(stringResource(R.string.activity_extensions), stats?.extensions.orEmpty().ifEmpty { listOf(context.getString(R.string.activity_none)) }.joinToString(", "))
    TextButton(onClick = {
        val report = "{\"status\": ${status.raw.ifEmpty { "null" }}, \"stats\": ${stats?.raw?.ifEmpty { null } ?: "null"}}"
        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("tsync report", report))
    }) { Text(stringResource(R.string.activity_copy_report)) }
}

@Composable
private fun Setting(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(label, style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun connection(store: StoreReport): String = when {
    store.down -> stringResource(R.string.activity_held_down, store.failures, DateUtils.formatElapsedTime(store.heldForSeconds.toLong()), store.downReason.orEmpty())
    store.reachable == false -> stringResource(R.string.activity_unreachable, store.unreachable.orEmpty())
    (store.latencyMs ?: 0.0) >= 1.0 -> stringResource(R.string.activity_connected_latency, store.latencyMs!!.toInt())
    else -> stringResource(R.string.state_connected)
}

@Composable
private fun damaged(store: StoreReport): String =
    pluralStringResource(R.plurals.activity_damaged, store.damagedChunks, store.damagedChunks) + if (store.damagedTruncated) "+" else ""

@Composable
private fun size(bytes: Long): String = Formatter.formatFileSize(LocalContext.current, bytes)

@Composable
fun Section(title: Int) {
    Text(
        stringResource(title),
        Modifier.padding(top = 24.dp, bottom = 8.dp).semantics { heading() },
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.primary,
    )
}
