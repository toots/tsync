@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)

package org.feverdreamtv.tsync.ui

import android.net.Uri
import android.text.format.DateUtils
import android.text.format.Formatter
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Notice
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Availability
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Item
import org.feverdreamtv.tsync.core.Naming
import org.feverdreamtv.tsync.core.Pull
import org.feverdreamtv.tsync.provider.TsyncDocumentsProvider

sealed interface FilesMode {
    data object Browse : FilesMode

    /** Choosing a destination folder: taps only navigate, and `hidden` is not offered. */
    class Pick(val title: @Composable (path: String) -> String, val hidden: String? = null, val onCancel: () -> Unit) : FilesMode
}

/** One folder's listing and how it stands: loading, loaded, failed, outdated (app §10.3). */
class FolderModel(private val tsync: Tsync, val ref: String, private val scope: CoroutineScope) {
    var items by mutableStateOf<List<Item>>(emptyList())
        private set
    var next by mutableStateOf<String?>(null)
        private set
    var loaded by mutableStateOf(false)
        private set
    var refreshing by mutableStateOf(false)
        private set
    var failure by mutableStateOf<CoreException?>(null)
        private set
    var outdatedSince by mutableStateOf<Long?>(null)
        private set
    var outdated by mutableStateOf(false)
        private set
    private var busy = false
    private var again = false

    /** Lists again, as many rows as are shown, so a refresh neither clears the list nor moves it. */
    fun load(pull: Pull = Pull.DEFAULT, byUser: Boolean = false) {
        if (busy) {
            again = true
            return
        }
        busy = true
        refreshing = byUser
        scope.launch {
            try {
                val listing = withContext(Dispatchers.IO) { tsync.ask { listDir(ref, limit = maxOf(PAGE, items.size), pull = pull) } }
                tsync.latch.listed(listing)
                items = listing.items
                next = listing.next
                outdated = listing.outdated
                outdatedSince = listing.pulledAt
                failure = null
                loaded = true
            } catch (e: CoreException) {
                failure = e
            } finally {
                busy = false
                refreshing = false
                if (again) {
                    again = false
                    load()
                }
            }
        }
    }

    fun more() {
        val after = next ?: return
        if (busy) return
        busy = true
        scope.launch {
            try {
                // A page asked with `after` continues the first page's view; its flags are the first page's.
                val page = withContext(Dispatchers.IO) { tsync.ask { listDir(ref, after = after, limit = PAGE) } }
                items = items + page.items
                next = page.next
            } catch (e: CoreException) {
                failure = e
            } finally {
                busy = false
            }
        }
    }

    private companion object {
        const val PAGE = 200
    }
}

@Composable
fun FilesScreen(
    tsync: Tsync,
    mode: FilesMode,
    trail: SnapshotStateList<Crumb>,
    outer: PaddingValues = PaddingValues(),
    onMove: (Item) -> Unit = {},
    bottomBar: @Composable (Crumb) -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val current = trail.last()
    val model = remember(current.ref) { FolderModel(tsync, current.ref, scope) }
    val path = trail.joinToString("/") { it.name }
    var readOnly by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Item?>(null) }
    var newFolder by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf<Save?>(null) }
    val running = remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        readOnly = withContext(Dispatchers.IO) { runCatching { tsync.client.status().readOnly }.getOrDefault(false) }
    }
    // Shown in the foreground, the folder is observed and listed again (app §7.1).
    LifecycleResumeEffect(current.ref) {
        model.load()
        tsync.observe(current.ref)
        onPauseOrDispose { tsync.unobserve(current.ref) }
    }
    LaunchedEffect(current.ref) {
        tsync.notices.collect { notice ->
            if (notice is Notice.Recovered || (notice is Notice.Changed && current.ref in notice.refs)) model.load()
        }
    }
    // The folder is gone: drop it from the view (failure-model §7.2).
    LaunchedEffect(model.failure) {
        if (model.failure?.code == Code.NOT_FOUND && trail.size > 1) trail.removeAt(trail.lastIndex)
    }
    BackHandler(enabled = trail.size > 1 || mode is FilesMode.Pick) {
        if (trail.size > 1) trail.removeAt(trail.lastIndex) else (mode as FilesMode.Pick).onCancel()
    }

    val upload = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            val save = Save(tsync, withContext(Dispatchers.IO) { Save.sources(context, uris) }, current.ref)
            saving = save
            val failed = save.stage()
            saving = null
            tsync.report(savedMessage(context, save.sources.size, failed), failed.isNotEmpty())
        }
    }

    Screen(
        title = if (mode is FilesMode.Pick) mode.title(path) else current.name,
        outer = outer,
        onBack = if (trail.size > 1) ({ trail.removeAt(trail.lastIndex) }) else null,
        bottomBar = { bottomBar(current) },
        floatingActionButton = {
            if (!readOnly) AddButton(uploads = mode is FilesMode.Browse, onNewFolder = { newFolder = true }, onUpload = { upload.launch(arrayOf("*/*")) })
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            TrailBar(trail)
            if (readOnly) Banner(stringResource(R.string.read_only_domain))
            if (model.loaded && model.outdated) Banner(stringResource(R.string.offline_as_of, age(model.outdatedSince)))
            if (model.loaded) model.failure?.let { Banner(it.message ?: it.code.wire) }
            running.value?.let { RunningBar(it, onHide = { running.value = null }) }
            PullToRefreshBox(isRefreshing = model.refreshing, onRefresh = { model.load(Pull.NOW, byUser = true) }, modifier = Modifier.fillMaxSize()) {
                Listing(model, mode, onOpenFolder = { trail.add(Crumb(it.ref, it.name)) }, onOpenFile = { openFile(tsync, context, it) }, onActions = { selected = it })
            }
        }
    }

    selected?.let { item ->
        ItemActions(tsync, item, readOnly || item.readOnly, running, onDismiss = { selected = null }, onMove = onMove)
    }
    if (newFolder) NamePrompt(
        title = stringResource(R.string.new_folder),
        initial = "",
        confirm = stringResource(R.string.create),
        onDismiss = { newFolder = false; model.load() },
        onSubmit = { name ->
            fieldError { tsync.ask { mkdir(current.ref, Naming.sanitizeLeaf(name), exclusive = true) } }
        },
    )
    saving?.let { SaveProgress(it) }
}

@Composable
private fun age(pulledAt: Long?): String {
    val context = LocalContext.current
    if (pulledAt == null) return stringResource(R.string.unknown_time)
    return DateUtils.formatDateTime(context, pulledAt * 1000, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_ALL)
}

fun savedMessage(context: android.content.Context, count: Int, failed: List<String>): String {
    val saved = count - failed.size
    val done = context.resources.getQuantityString(R.plurals.files_saved, saved, saved)
    return if (failed.isEmpty()) done else done + " " + context.getString(R.string.could_not_copy, failed.joinToString(", "))
}

@Composable
private fun TrailBar(trail: SnapshotStateList<Crumb>) {
    val scroll = rememberScrollState()
    LaunchedEffect(trail.size) { scroll.scrollTo(scroll.maxValue) }
    Row(Modifier.fillMaxWidth().horizontalScroll(scroll).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        trail.forEachIndexed { index, crumb ->
            if (index > 0) Text("/", color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = { while (trail.size > index + 1) trail.removeAt(trail.lastIndex) }, enabled = index < trail.lastIndex) {
                Text(crumb.name, maxLines = 1)
            }
        }
    }
}

@Composable
fun Banner(text: String) {
    Surface(color = MaterialTheme.colorScheme.secondaryContainer, modifier = Modifier.fillMaxWidth()) {
        Text(text, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun RunningBar(label: String, onHide: () -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            TextButton(onClick = onHide) { Text(stringResource(R.string.hide)) }
        }
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
private fun AddButton(uploads: Boolean, onNewFolder: () -> Unit, onUpload: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        FloatingActionButton(onClick = { if (uploads) open = true else onNewFolder() }) {
            Icon(painterResource(R.drawable.ic_add), contentDescription = stringResource(if (uploads) R.string.add else R.string.new_folder))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.new_folder)) }, onClick = { open = false; onNewFolder() })
            DropdownMenuItem(text = { Text(stringResource(R.string.upload_files)) }, onClick = { open = false; onUpload() })
        }
    }
}

@Composable
private fun Listing(model: FolderModel, mode: FilesMode, onOpenFolder: (Item) -> Unit, onOpenFile: (Item) -> Unit, onActions: (Item) -> Unit) {
    val failure = model.failure
    when {
        !model.loaded && failure == null -> Loading()
        !model.loaded && failure != null -> Failure(
            reason = if (failure.code == Code.UNREACHABLE) stringResource(R.string.cannot_reach_server) else failure.message ?: failure.code.wire,
            onRetry = { model.load() },
        )
        model.items.isEmpty() && model.next == null -> Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) { Text(stringResource(R.string.empty_folder)) }
        else -> {
            val state = rememberLazyListState()
            val nearEnd by remember { derivedStateOf { (state.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) >= state.layoutInfo.totalItemsCount - 20 } }
            LaunchedEffect(nearEnd, model.next) { if (nearEnd && model.next != null) model.more() }
            val picking = mode is FilesMode.Pick
            val shown = if (mode is FilesMode.Pick) model.items.filter { it.ref != mode.hidden } else model.items
            LazyColumn(Modifier.fillMaxSize(), state = state, contentPadding = PaddingValues(bottom = 88.dp)) {
                items(shown, key = { it.ref }) { item ->
                    ItemRow(
                        item = item,
                        enabled = !picking || item.isDir,
                        onClick = { if (item.isDir) onOpenFolder(item) else if (!picking) onOpenFile(item) },
                        onActions = if (picking) null else ({ onActions(item) }),
                    )
                }
            }
        }
    }
}

/** What the state mark says: waiting to upload takes precedence over where the bytes are. */
private fun stateMark(item: Item): Pair<Int, Int>? = when {
    item.isDir -> null
    !item.isUploaded -> R.drawable.ic_waiting to R.string.state_waiting_upload
    item.availability == Availability.ONLINE_ONLY -> R.drawable.ic_cloud to R.string.state_online_only
    item.availability == Availability.PINNED -> R.drawable.ic_pinned to R.string.state_pinned
    else -> null
}

private fun kindIcon(item: Item): Int {
    if (item.isDir) return R.drawable.ic_folder
    val type = TsyncDocumentsProvider.mimeType(item.name)
    return when {
        type.startsWith("image/") -> R.drawable.ic_image
        type.startsWith("video/") -> R.drawable.ic_video
        type.startsWith("audio/") -> R.drawable.ic_audio
        else -> R.drawable.ic_file
    }
}

@Composable
private fun ItemRow(item: Item, enabled: Boolean, onClick: () -> Unit, onActions: (() -> Unit)?) {
    val context = LocalContext.current
    val mark = stateMark(item)
    val details = if (item.isDir) null else listOfNotNull(
        Formatter.formatShortFileSize(context, item.size),
        item.mtimeMillis.takeIf { it > 0 }?.let { DateUtils.formatDateTime(context, it, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_ALL) },
        mark?.let { stringResource(it.second) },
    ).joinToString(" · ")
    ListItem(
        modifier = Modifier.alpha(if (enabled) 1f else 0.5f)
            .combinedClickable(enabled = enabled, onClick = onClick, onLongClick = onActions),
        leadingContent = { Icon(painterResource(kindIcon(item)), contentDescription = stringResource(if (item.isDir) R.string.kind_folder else R.string.kind_file)) },
        headlineContent = { Text(item.name) },
        supportingContent = details?.let { { Text(it) } },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (mark != null) Icon(painterResource(mark.first), contentDescription = null)
                if (onActions != null) IconButton(onClick = onActions) {
                    Icon(painterResource(R.drawable.ic_more), contentDescription = stringResource(R.string.actions_for, item.name))
                }
            }
        },
    )
}

/** The share target: Files in pick mode, then the save (app §10.6). */
@Composable
fun SaveTarget(tsync: Tsync, uris: List<Uri>, onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val trail = rememberTrail(tsync.domain)
    var sources by remember { mutableStateOf<List<Source>?>(null) }
    var name by rememberSaveable { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf<Save?>(null) }
    LaunchedEffect(uris) {
        val named = withContext(Dispatchers.IO) { Save.sources(context, uris) }
        sources = named
        if (name == null) name = named.singleOrNull()?.name
    }
    val count = uris.size
    FilesScreen(
        tsync = tsync,
        mode = FilesMode.Pick(title = { pluralStringResource(R.plurals.save_files_to, count, count, it) }, onCancel = onDone),
        trail = trail,
        bottomBar = { folder ->
            PickBar(confirm = stringResource(R.string.save_here), enabled = sources != null && saving == null, onCancel = onDone, onConfirm = {
                val chosen = sources.orEmpty().map { if (count == 1) it.copy(name = name.orEmpty()) else it }
                scope.launch {
                    val save = Save(tsync, chosen, folder.ref)
                    saving = save
                    val failed = save.stage()
                    Toast.makeText(context, savedMessage(context, count, failed), Toast.LENGTH_LONG).show()
                    onDone()
                }
            }) {
                if (count == 1) OutlinedTextField(
                    value = name.orEmpty(),
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.name)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
                )
            }
        },
    )
    saving?.let { SaveProgress(it) }
}

/** Files in pick mode choosing where an item moves (app §10.4). */
@Composable
fun MoveTarget(tsync: Tsync, item: Item, outer: PaddingValues, onDone: () -> Unit) {
    val context = LocalContext.current
    val trail = rememberTrail(tsync.domain)
    FilesScreen(
        tsync = tsync,
        mode = FilesMode.Pick(title = { stringResource(R.string.move_to, item.name, it) }, hidden = item.ref, onCancel = onDone),
        trail = trail,
        outer = outer,
        bottomBar = { folder ->
            PickBar(confirm = stringResource(R.string.move_here), enabled = true, onCancel = onDone, onConfirm = {
                val path = trail.joinToString("/") { it.name }
                tsync.scope.launch {
                    try {
                        tsync.ask { rename(item.ref, folder.ref, item.name) }
                        tsync.report(context.getString(R.string.moved_to, item.name, path))
                    } catch (e: CoreException) {
                        tsync.report(e.message ?: e.code.wire, failed = true)
                    }
                }
                onDone()
            })
        },
    )
}

@Composable
private fun PickBar(confirm: String, enabled: Boolean, onCancel: () -> Unit, onConfirm: () -> Unit, extra: @Composable () -> Unit = {}) {
    Surface(tonalElevation = 3.dp) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp)) {
            extra()
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) }
                Button(onClick = onConfirm, enabled = enabled, modifier = Modifier.padding(start = 8.dp)) { Text(confirm) }
            }
        }
    }
}
