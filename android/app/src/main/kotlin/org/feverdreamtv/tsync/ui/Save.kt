package org.feverdreamtv.tsync.ui

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.feverdreamtv.tsync.Notifications
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.KeepAliveCounter.Work
import org.feverdreamtv.tsync.core.Naming
import org.feverdreamtv.tsync.core.Target

data class Source(val uri: Uri, val name: String)

enum class Copy(val label: Int) {
    WAITING(R.string.copy_waiting),
    COPYING(R.string.copy_copying),
    READY(R.string.copy_ready),
    FAILED(R.string.copy_failed),
}

/** One save into a folder, from the share target or from "Upload files" (app §10.6). */
class Save(private val tsync: Tsync, val sources: List<Source>, private val parentRef: String) {
    val progress = MutableStateFlow(sources.map { Copy.WAITING })

    /**
     * Returns once every file has a ready intent or failed to copy; commits go on afterwards,
     * whatever happens to the screen that asked.
     * @return the names that could not be copied
     */
    suspend fun stage(): List<String> = tsync.scope.async {
        tsync.keepAlive.retain(Work.SAVE)
        val ready = try {
            sources.mapIndexedNotNull { index, source -> copy(index, source)?.let { it to source.name } }
        } catch (e: Throwable) {
            tsync.keepAlive.release(Work.SAVE)
            throw e
        }
        tsync.scope.launch { commit(ready) }
        sources.filterIndexed { index, _ -> progress.value[index] == Copy.FAILED }.map { it.name }
    }.await()

    private fun mark(index: Int, state: Copy) = progress.update { states -> states.toMutableList().also { it[index] = state } }

    private fun copy(index: Int, source: Source): String? {
        mark(index, Copy.COPYING)
        val ingest = tsync.ingest
        val staging = ingest.stage(Target.Child(parentRef, Naming.sanitizeLeaf(source.name)), exclusive = true)
        return try {
            val input = tsync.context.contentResolver.openInputStream(source.uri) ?: throw java.io.IOException("no stream")
            input.use { ingest.staging(staging).outputStream().use(it::copyTo) }
            ingest.markReady(staging)
            mark(index, Copy.READY)
            staging
        } catch (e: Exception) {
            ingest.abandon(staging)
            mark(index, Copy.FAILED)
            null
        }
    }

    private fun commit(ready: List<Pair<String, String>>) {
        try {
            for ((staging, name) in ready) {
                Notifications.saveOutcome(tsync, staging, name, runCatching { tsync.ingest.commit(staging) })
            }
        } finally {
            tsync.keepAlive.release(Work.SAVE)
        }
    }

    companion object {
        fun sources(context: Context, uris: List<Uri>): List<Source> = uris.map { Source(it, displayName(context, it)) }

        // The stream's display name, else its last address segment, else a fixed name.
        private fun displayName(context: Context, uri: Uri): String {
            val named = try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null
                }
            } catch (e: Exception) {
                null
            }
            return named?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment?.takeIf { it.isNotBlank() } ?: context.getString(R.string.shared_file)
        }
    }
}

@Composable
fun SaveProgress(save: Save) {
    val states by save.progress.collectAsState()
    AlertDialog(
        onDismissRequest = {},
        confirmButton = {},
        title = { Text(pluralStringResource(R.plurals.saving_files, save.sources.size, save.sources.size)) },
        text = {
            Column {
                LinearProgressIndicator(
                    progress = { states.count { it == Copy.READY || it == Copy.FAILED }.toFloat() / states.size.coerceAtLeast(1) },
                    modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
                )
                if (save.sources.size > 1) Column(Modifier.heightIn(max = 240.dp).verticalScroll(rememberScrollState())) {
                    save.sources.forEachIndexed { index, source ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                            Text(source.name, Modifier.weight(1f), maxLines = 1)
                            Text(stringResource(states[index].label), Modifier.padding(start = 8.dp))
                        }
                    }
                }
            }
        },
    )
}
