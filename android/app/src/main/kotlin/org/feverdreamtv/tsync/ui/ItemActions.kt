@file:OptIn(ExperimentalMaterial3Api::class)

package org.feverdreamtv.tsync.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.provider.DocumentsContract
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Availability
import org.feverdreamtv.tsync.core.Client
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Counts
import org.feverdreamtv.tsync.core.Item
import org.feverdreamtv.tsync.core.Naming
import org.feverdreamtv.tsync.core.ShareLink
import org.feverdreamtv.tsync.provider.TsyncDocumentsProvider

private enum class Prompt { RENAME, DELETE, DETAILS }

/** Runs a request for a name field: null when done, the owner's sentence for the field otherwise. */
suspend fun fieldError(request: () -> Unit): String? = withContext(Dispatchers.IO) {
    try {
        request()
        null
    } catch (e: CoreException) {
        e.message ?: e.code.wire
    }
}

/** A view intent on the document, through the system chooser (app §10.4). */
fun openFile(tsync: Tsync, context: Context, item: Item) {
    val view = Intent(Intent.ACTION_VIEW)
        .setDataAndType(DocumentsContract.buildDocumentUri(Tsync.AUTHORITY, item.ref), TsyncDocumentsProvider.mimeType(item.name))
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    if (context.packageManager.queryIntentActivities(view, 0).isEmpty()) {
        tsync.report(context.getString(R.string.no_app_opens, item.name), failed = true)
    } else {
        context.startActivity(Intent.createChooser(view, item.name))
    }
}

/**
 * Runs an action that may outlive the screen: it shows as running, then says how it ended, on
 * screen or as a notification (app §10.4).
 */
private fun act(tsync: Tsync, running: MutableState<String?>, label: String, action: Client.() -> String) {
    running.value = label
    tsync.scope.launch {
        val (text, failed) = try {
            tsync.ask(action) to false
        } catch (e: CoreException) {
            (e.message ?: e.code.wire) to true
        }
        if (running.value == label) running.value = null
        tsync.report(text, failed)
    }
}

private fun counted(context: Context, item: Item, counts: Counts, plural: Int, single: Int): String {
    if (!item.isDir) return context.getString(single, item.name)
    val done = context.resources.getQuantityString(plural, counts.done, counts.done)
    return if (counts.failed == 0) done else done + ", " + context.getString(R.string.count_failed, counts.failed)
}

@Composable
fun ItemActions(tsync: Tsync, item: Item, readOnly: Boolean, running: MutableState<String?>, onDismiss: () -> Unit, onMove: (Item) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var prompt by remember { mutableStateOf<Prompt?>(null) }
    var link by remember { mutableStateOf<ShareLink?>(null) }
    val pinned = item.availability == Availability.PINNED

    @Composable
    fun action(label: Int, onClick: () -> Unit) {
        ListItem(headlineContent = { Text(stringResource(label)) }, modifier = Modifier.clickable(onClick = onClick))
    }

    fun restore() = act(tsync, running, context.getString(R.string.making_available, item.name)) {
        counted(context, item, restore(item.ref), R.plurals.files_available_offline, R.string.available_offline)
    }

    if (prompt == null && link == null) ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.navigationBarsPadding().verticalScroll(rememberScrollState())) {
            Text(
                item.name,
                Modifier.padding(horizontal = 16.dp, vertical = 8.dp).semantics { heading() },
                style = MaterialTheme.typography.titleMedium,
            )
            if (!item.isDir) action(R.string.action_open) { onDismiss(); openFile(tsync, context, item) }
            action(R.string.action_share_link) {
                scope.launch {
                    try {
                        link = withContext(Dispatchers.IO) { tsync.ask { share(item.ref) } }
                    } catch (e: CoreException) {
                        tsync.report(e.message ?: e.code.wire, failed = true)
                        onDismiss()
                    }
                }
            }
            if (!pinned) action(R.string.action_make_available) { onDismiss(); restore() }
            if (pinned && !item.isDir) action(R.string.action_keep_longer) { onDismiss(); restore() }
            if (item.isDir || item.availability != Availability.ONLINE_ONLY) action(R.string.action_remove_download) {
                onDismiss()
                act(tsync, running, context.getString(R.string.removing_download, item.name)) {
                    counted(context, item, evict(item.ref), R.plurals.downloads_removed, R.string.download_removed)
                }
            }
            if (!readOnly) {
                action(R.string.action_rename) { prompt = Prompt.RENAME }
                action(R.string.action_move) { onDismiss(); onMove(item) }
                action(R.string.action_delete) { prompt = Prompt.DELETE }
            }
            action(R.string.action_details) { prompt = Prompt.DETAILS }
        }
    }

    when (prompt) {
        Prompt.RENAME -> NamePrompt(
            title = stringResource(R.string.action_rename),
            initial = item.name,
            confirm = stringResource(R.string.action_rename),
            onDismiss = onDismiss,
            onSubmit = { name ->
                fieldError { tsync.ask { rename(item.ref, item.parentRef, Naming.sanitizeLeaf(name)) } }
                    .also { if (it == null) tsync.report(context.getString(R.string.renamed, name)) }
            },
        )
        Prompt.DELETE -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(stringResource(R.string.delete_title, item.name)) },
            text = { Text(stringResource(if (item.isDir) R.string.delete_folder_text else R.string.delete_file_text, item.name)) },
            dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
            confirmButton = {
                TextButton(onClick = {
                    onDismiss()
                    act(tsync, running, context.getString(R.string.deleting, item.name)) {
                        try {
                            delete(item)
                        } catch (e: CoreException) {
                            // Gone already: the delete succeeded.
                            if (e.code != Code.NOT_FOUND) throw e
                        }
                        context.getString(R.string.deleted, item.name)
                    }
                }) { Text(stringResource(R.string.action_delete)) }
            },
        )
        Prompt.DETAILS -> Details(item, onDismiss)
        null -> Unit
    }
    link?.let { LinkDialog(item, it, onDismiss) }
}

@Composable
private fun LinkDialog(item: Item, link: ShareLink, onDismiss: () -> Unit) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.link_title, item.name)) },
        text = {
            Column {
                SelectionContainer { Text(link.url) }
                Text(stringResource(R.string.link_expires, dateTime(context, link.expires * 1000)), Modifier.padding(top = 8.dp))
            }
        },
        dismissButton = {
            TextButton(onClick = {
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(item.name, link.url))
                onDismiss()
            }) { Text(stringResource(R.string.copy)) }
        },
        confirmButton = {
            TextButton(onClick = {
                val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, link.url)
                context.startActivity(Intent.createChooser(send, null))
                onDismiss()
            }) { Text(stringResource(R.string.send)) }
        },
    )
}

private fun dateTime(context: Context, millis: Long): String =
    DateUtils.formatDateTime(context, millis, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_SHOW_YEAR)

@Composable
private fun Details(item: Item, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val where = when {
        item.isDir -> null
        item.availability == Availability.ONLINE_ONLY -> R.string.state_online_only
        item.availability == Availability.PINNED -> R.string.state_pinned
        else -> R.string.state_cached
    }
    val lines = listOfNotNull(
        R.string.detail_name to item.name,
        R.string.detail_kind to stringResource(if (item.isDir) R.string.kind_folder else R.string.kind_file),
        if (item.isDir) null else R.string.detail_size to Formatter.formatFileSize(context, item.size),
        item.mtimeMillis.takeIf { it > 0 }?.let { R.string.detail_modified to dateTime(context, it) },
        where?.let { R.string.detail_bytes to stringResource(it) },
        item.pinnedUntil?.let { R.string.detail_pinned_until to dateTime(context, it * 1000) },
        R.string.detail_uploaded to stringResource(if (item.isUploaded) R.string.yes else R.string.state_waiting_upload),
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.action_details)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                for ((label, value) in lines) {
                    Text(stringResource(label), style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 8.dp))
                    SelectionContainer { Text(value) }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
    )
}

/** A name field whose failure, such as a taken name, is shown on the field. */
@Composable
fun NamePrompt(title: String, initial: String, confirm: String, onDismiss: () -> Unit, onSubmit: suspend (String) -> String?) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(initial) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it; error = null },
                label = { Text(stringResource(R.string.name)) },
                singleLine = true,
                isError = error != null,
                supportingText = error?.let { { Text(it) } },
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
        confirmButton = {
            if (busy) CircularProgressIndicator() else TextButton(enabled = name.isNotBlank(), onClick = {
                busy = true
                scope.launch {
                    error = onSubmit(name)
                    busy = false
                    if (error == null) onDismiss()
                }
            }) { Text(confirm) }
        },
    )
}
