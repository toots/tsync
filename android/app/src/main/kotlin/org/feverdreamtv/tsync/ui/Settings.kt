package org.feverdreamtv.tsync.ui

import android.Manifest
import android.app.Activity
import android.os.Build
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ListItem
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.BuildConfig
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.backup.Access
import org.feverdreamtv.tsync.backup.Backup
import org.feverdreamtv.tsync.backup.BackupSchedule
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.ServerConfig
import org.feverdreamtv.tsync.core.SetupAnswer
import org.feverdreamtv.tsync.core.SetupDomain
import org.feverdreamtv.tsync.core.SetupLink
import org.feverdreamtv.tsync.core.Stats
import org.feverdreamtv.tsync.core.backup.BackupSettings

/** Shown alone until a config names a domain, with the core's sentence for one that does not load (app §10.2, §10.7). */
@Composable
fun SetupScreen(tsync: Tsync, refusal: String?, replace: Boolean, onJoined: () -> Unit) {
    Screen(stringResource(R.string.setup_title)) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(16.dp)) {
            refusal?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(bottom = 8.dp)) }
            JoinForm(tsync, replace, onJoined)
        }
    }
}

/**
 * A setup link, scanned or pasted, then a choice of its domains and **Join** (app §6.1, §10.7,
 * setup-link §6.3). There is no manual entry. A domain the config already names is not offered.
 */
@Composable
private fun JoinForm(tsync: Tsync, replace: Boolean, onJoined: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var link by rememberSaveable { mutableStateOf("") }
    var said by remember { mutableStateOf<String?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var offered by remember { mutableStateOf<List<SetupDomain>>(emptyList()) }
    val picked = remember { mutableStateListOf<String>() }
    var busy by remember { mutableStateOf(false) }

    fun open(text: String) {
        busy = true
        failure = null
        scope.launch {
            val (answer, known) = withContext(Dispatchers.IO) {
                try {
                    SetupLink.parse(tsync.setupLink(text.trim())) to if (replace) emptyList() else tsync.config.names()
                } catch (e: Throwable) {
                    SetupAnswer.Refused(e.message ?: e.toString()) to emptyList()
                }
            }
            busy = false
            picked.clear()
            offered = emptyList()
            when (answer) {
                is SetupAnswer.Refused -> said = answer.reason
                is SetupAnswer.Opened -> {
                    offered = answer.domains.filter { it.name !in known }
                    offered.singleOrNull()?.let { picked += it.name }
                    said = (listOfNotNull(answer.from.takeIf { it.isNotEmpty() }?.let { context.getString(R.string.setup_link_from, it) }) +
                        answer.skipped.map { context.getString(R.string.setup_link_skipped, it) } +
                        listOfNotNull(context.getString(R.string.setup_link_nothing).takeIf { offered.isEmpty() })).joinToString("\n")
                }
            }
        }
    }

    val scanner = playServices(context)
    OutlinedButton(enabled = !busy && scanner, onClick = { scan(context, { link = it; open(it) }) { said = it } }) {
        Text(stringResource(R.string.setup_scan))
    }
    if (!scanner) Text(stringResource(R.string.code_scan_unavailable), Modifier.padding(bottom = 8.dp))
    OutlinedTextField(
        value = link,
        onValueChange = { link = it },
        label = { Text(stringResource(R.string.setup_link)) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
    )
    OutlinedButton(enabled = !busy && link.isNotBlank(), onClick = { open(link) }) { Text(stringResource(R.string.setup_open_link)) }
    said?.let { Text(it, Modifier.padding(vertical = 8.dp)) }
    offered.forEach { offer ->
        val look = offer.look
        Row(
            Modifier.fillMaxWidth().toggleable(offer.name in picked, !busy, Role.Checkbox) { on -> if (on) picked += offer.name else picked -= offer.name }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Checkbox(checked = offer.name in picked, onCheckedChange = null)
            if (look != null) VaultMark(look, Modifier.padding(horizontal = 8.dp))
            Text(offer.name, Modifier.padding(start = 8.dp))
        }
    }
    failure?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(vertical = 8.dp)) }
    if (offered.isNotEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
        Button(enabled = !busy && picked.isNotEmpty(), onClick = {
            val joining = offered.filter { it.name in picked }.map { ServerConfig(it.url, it.secret, it.name) }
            busy = true
            scope.launch {
                // A candidate the core refuses never becomes the config; its sentence is shown verbatim.
                failure = withContext(Dispatchers.IO) {
                    try {
                        tsync.prepare()
                        tsync.config.add(joining, Build.MODEL.orEmpty(), replace) { domain, candidate -> tsync.domain(domain).core.checkConfig(candidate) }
                    } catch (e: Throwable) {
                        e.message ?: e.toString()
                    }
                }
                busy = false
                if (failure == null) {
                    tsync.notifyRoots()
                    onJoined()
                }
            }
        }) { Text(stringResource(R.string.setup_join)) }
        if (busy) CircularProgressIndicator(Modifier.padding(start = 16.dp))
    }
}

private data class Storage(val cache: Long?, val staged: Long?, val stats: Stats?)

@Composable
fun SettingsScreen(tsync: Tsync, domains: List<String>, outer: PaddingValues, onConfigChanged: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var config by remember { mutableStateOf<List<ServerConfig>?>(null) }
    var storage by remember { mutableStateOf<Map<String, Storage?>>(emptyMap()) }
    var adding by rememberSaveable { mutableStateOf(false) }
    var removing by remember { mutableStateOf<String?>(null) }
    var restart by remember { mutableStateOf(false) }
    var freeing by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(domains) {
        config = withContext(Dispatchers.IO) { tsync.config.read() }
        // Asked of the booted domains only: Settings boots none (app §2).
        storage = withContext(Dispatchers.IO) {
            domains.associateWith { name ->
                val domain = tsync.domain(name)
                if (domain.boot != Boot.Ready) null
                else {
                    val stats = runCatching { domain.ask { stats() } }.getOrNull()
                    Storage(stats?.cacheBytes, runCatching { domain.ask { status() }.pendingBytes }.getOrNull(), stats)
                }
            }
        }
    }
    if (adding) {
        BackHandler { adding = false }
        Screen(stringResource(R.string.add_domain), outer, onBack = { adding = false }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp)) {
                JoinForm(tsync, replace = false, onJoined = { adding = false; onConfigChanged() })
            }
        }
        return
    }
    Screen(stringResource(R.string.destination_settings), outer) { padding ->
        val entries = config
        if (entries == null) {
            Loading(padding)
            return@Screen
        }
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp)) {
            Section(R.string.settings_domains)
            entries.forEach { entry ->
                val failed = tsync.domain(entry.domain).boot as? Boot.Failed
                ListItem(
                    headlineContent = { Text(entry.domain) },
                    supportingContent = {
                        Column {
                            Text(entry.url)
                            failed?.let { Text(it.reason, color = MaterialTheme.colorScheme.error) }
                        }
                    },
                    trailingContent = { TextButton(onClick = { removing = entry.domain }) { Text(stringResource(R.string.remove)) } },
                )
            }
            OutlinedButton(onClick = { adding = true }, modifier = Modifier.padding(top = 8.dp)) { Text(stringResource(R.string.add_domain)) }

            Section(R.string.settings_storage)
            entries.forEach { entry ->
                val it = storage[entry.domain]
                Text(entry.domain, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 8.dp))
                Text(stringResource(R.string.storage_limit, entry.maxCache))
                if (it == null) {
                    Text(stringResource(R.string.domain_not_booted))
                    return@forEach
                }
                it.stats?.let { stats ->
                    val names = if (stats.extensions.isEmpty()) stringResource(R.string.settings_extensions_none) else stats.extensions.joinToString(", ")
                    Text(stringResource(R.string.settings_extensions, if (stats.extensionsFromServer && stats.extensions.isNotEmpty()) stringResource(R.string.settings_extensions_server, names) else names))
                }
                fun size(bytes: Long?) = bytes?.let { value -> Formatter.formatFileSize(context, value) } ?: context.getString(R.string.unknown_size)
                Text(stringResource(R.string.storage_cache, size(it.cache)))
                Text(stringResource(R.string.storage_staged, size(it.staged)))
                OutlinedButton(onClick = { freeing = entry.domain }, modifier = Modifier.padding(top = 8.dp)) { Text(stringResource(R.string.free_up_space)) }
            }

            Section(R.string.camera_backup)
            BackupControls(tsync, domains)

            Section(R.string.settings_about)
            Text(stringResource(R.string.about_version, BuildConfig.VERSION_NAME))
            Text(stringResource(R.string.about_commit, BuildConfig.COMMIT))
        }
    }
    removing?.let { name ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text(stringResource(R.string.remove_domain_title, name)) },
            text = { Text(stringResource(R.string.remove_domain_text)) },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(stringResource(R.string.cancel)) } },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    scope.launch {
                        val refusal = withContext(Dispatchers.IO) {
                            try {
                                tsync.prepare()
                                tsync.config.remove(name) { domain, candidate -> tsync.domain(domain).core.checkConfig(candidate) }
                            } catch (e: Throwable) {
                                e.message ?: e.toString()
                            }
                        }
                        if (refusal != null) return@launch tsync.report(refusal, failed = true)
                        // The platform is told either way; a booted domain serves as it booted until the process dies.
                        tsync.notifyRoots()
                        if (tsync.domain(name).boot == Boot.Ready) restart = true
                        onConfigChanged()
                    }
                }) { Text(stringResource(R.string.remove)) }
            },
        )
    }
    if (restart) AlertDialog(
        onDismissRequest = { restart = false },
        title = { Text(stringResource(R.string.restart_title)) },
        text = { Text(stringResource(R.string.restart_text)) },
        dismissButton = { TextButton(onClick = { restart = false }) { Text(stringResource(R.string.later)) } },
        confirmButton = {
            TextButton(onClick = {
                (context as? Activity)?.finishAffinity()
                Runtime.getRuntime().exit(0)
            }) { Text(stringResource(R.string.restart_now)) }
        },
    )
    freeing?.let { name ->
        AlertDialog(
            onDismissRequest = { freeing = null },
            title = { Text(stringResource(R.string.free_up_space)) },
            text = { Text(stringResource(R.string.free_up_text)) },
            dismissButton = { TextButton(onClick = { freeing = null }) { Text(stringResource(R.string.cancel)) } },
            confirmButton = {
                TextButton(onClick = {
                    freeing = null
                    scope.launch {
                        try {
                            val counts = withContext(Dispatchers.IO) { tsync.domain(name).ask { evict(Parameters.ROOT) } }
                            val done = context.resources.getQuantityString(R.plurals.downloads_removed, counts.done, counts.done)
                            tsync.report(if (counts.failed == 0) done else done + ", " + context.getString(R.string.count_failed, counts.failed), counts.failed > 0)
                        } catch (e: CoreException) {
                            tsync.report(e.message ?: e.code.wire, failed = true)
                        }
                    }
                }) { Text(stringResource(R.string.free_up_space)) }
            },
        )
    }
}

@Composable
private fun SwitchRow(label: Int, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().toggleable(checked, enabled, Role.Switch, onChange).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(stringResource(label), Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

/** app §11.6: the switch, the domain it backs up to, its two conditions, and "Back up now". */
@Composable
private fun BackupControls(tsync: Tsync, domains: List<String>) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val backup = remember { Backup(context) }
    var settings by remember { mutableStateOf(backup.prefs.settings) }
    var status by remember { mutableStateOf("") }
    var refresh by remember { mutableIntStateOf(0) }
    var choosing by remember { mutableStateOf(false) }
    var fromNowOn by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(refresh) { status = withContext(Dispatchers.IO) { backup.statusLine() } }

    fun store(changed: BackupSettings) {
        settings = changed
        backup.prefs.settings = changed
        if (changed.enabled) BackupSchedule.schedule(context, changed) else BackupSchedule.cancel(context)
        refresh++
    }

    // Enabled only once read access is granted; "from now on" first records what exists.
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (backup.access() == Access.DENIED) {
            tsync.report(context.getString(R.string.backup_no_access), failed = true)
            return@rememberLauncherForActivityResult
        }
        busy = true
        scope.launch {
            val failure = withContext(Dispatchers.IO) {
                try {
                    if (fromNowOn) backup.discover(baseline = true)
                    null
                } catch (e: Exception) {
                    e.message ?: e.toString()
                }
            }
            busy = false
            if (failure == null) store(settings.copy(enabled = true)) else tsync.report(context.getString(R.string.backup_not_enabled, failure), failed = true)
        }
    }

    SwitchRow(R.string.backup_enable, settings.enabled, enabled = !busy) { on ->
        if (on) choosing = true else store(settings.copy(enabled = false))
    }
    var target by remember { mutableStateOf(backup.target(domains)) }
    if (domains.size > 1 || target == null) {
        Text(stringResource(R.string.backup_to), Modifier.padding(top = 8.dp))
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            domains.forEach { name ->
                FilterChip(
                    selected = target == name,
                    onClick = { target = name; backup.prefs.domain = name; refresh++ },
                    label = { Text(name) },
                    modifier = Modifier.padding(end = 8.dp),
                )
            }
        }
    }
    SwitchRow(R.string.backup_wifi_only, settings.unmeteredOnly) { store(settings.copy(unmeteredOnly = it)) }
    SwitchRow(R.string.backup_battery, settings.whenBatteryOk) { store(settings.copy(whenBatteryOk = it)) }
    Text(status, style = MaterialTheme.typography.bodyMedium)
    if (busy) CircularProgressIndicator(Modifier.padding(top = 8.dp))
    if (settings.enabled) Button(onClick = { BackupSchedule.runNow(context); refresh++ }, modifier = Modifier.padding(top = 8.dp)) {
        Text(stringResource(R.string.back_up_now))
    }

    if (choosing) AlertDialog(
        onDismissRequest = { choosing = false },
        title = { Text(stringResource(R.string.backup_enable)) },
        text = { Text(stringResource(R.string.backup_scope_text)) },
        dismissButton = {
            TextButton(onClick = { choosing = false; fromNowOn = true; permissions.launch(mediaPermissions()) }) { Text(stringResource(R.string.backup_from_now_on)) }
        },
        confirmButton = {
            TextButton(onClick = { choosing = false; fromNowOn = false; permissions.launch(mediaPermissions()) }) { Text(stringResource(R.string.backup_everything)) }
        },
    )
}

private fun mediaPermissions(): Array<String> = buildList {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        add(Manifest.permission.READ_MEDIA_IMAGES)
        add(Manifest.permission.READ_MEDIA_VIDEO)
        add(Manifest.permission.POST_NOTIFICATIONS)
    } else {
        add(Manifest.permission.READ_EXTERNAL_STORAGE)
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) add(Manifest.permission.ACCESS_MEDIA_LOCATION)
}.toTypedArray()
