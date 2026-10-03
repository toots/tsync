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
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
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
import org.feverdreamtv.tsync.core.CheckServer
import org.feverdreamtv.tsync.core.ConfigForm
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.FormError
import org.feverdreamtv.tsync.core.FormField
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.ServerAnswer
import org.feverdreamtv.tsync.core.ServerConfig
import org.feverdreamtv.tsync.core.backup.BackupSettings

private fun message(error: FormError): Int = when (error) {
    FormError.URL_MALFORMED -> R.string.error_url_malformed
    FormError.URL_CLEARTEXT -> R.string.error_url_cleartext
    FormError.SECRET_TOO_SHORT -> R.string.error_secret_short
    FormError.DOMAIN_INVALID -> R.string.error_domain_invalid
}

/** Shown alone until a config exists, and again for a config the core refuses (app §10.2, §10.7). */
@Composable
fun SetupScreen(refused: ServerConfig?, refusal: String?, onConnected: () -> Unit) {
    val tsync = Tsync.get(LocalContext.current)
    Screen(stringResource(R.string.setup_title)) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(16.dp)) {
            ServerForm(tsync, refused, refusal, stringResource(R.string.connect), onSaved = { onConnected() })
        }
    }
}

/**
 * Server URL and secret, Check server, the domain, the cache limit, and the save (app §6.1,
 * §6.2). Each failure is shown on its field, which takes focus and so scrolls into view.
 */
@Composable
private fun ServerForm(tsync: Tsync, initial: ServerConfig?, refusal: String?, saveLabel: String, onSaved: (ServerConfig) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var url by rememberSaveable { mutableStateOf(initial?.url.orEmpty()) }
    var secret by rememberSaveable { mutableStateOf(initial?.secret.orEmpty()) }
    var domain by rememberSaveable { mutableStateOf(initial?.domain.orEmpty()) }
    var cache by rememberSaveable { mutableStateOf(initial?.maxCache?.takeIf { it.isNotBlank() } ?: Parameters.DEFAULT_MAX_CACHE) }
    var reveal by rememberSaveable { mutableStateOf(false) }
    var error by remember { mutableStateOf<FormError?>(null) }
    var failure by remember { mutableStateOf(refusal) }
    var checked by remember { mutableStateOf<String?>(null) }
    var offered by remember { mutableStateOf<List<String>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    val focus = remember { FormField.entries.associateWith { FocusRequester() } }

    @Composable
    fun field(field: FormField, value: String, label: Int, onChange: (String) -> Unit, secretField: Boolean = false) {
        val problem = error?.takeIf { it.field == field }?.let { stringResource(message(it)) }
        OutlinedTextField(
            value = value,
            onValueChange = { onChange(it); if (error?.field == field) error = null },
            label = { Text(stringResource(label)) },
            singleLine = true,
            isError = problem != null,
            supportingText = problem?.let { { Text(it) } },
            visualTransformation = if (secretField && !reveal) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = if (secretField) KeyboardType.Password else if (field == FormField.URL) KeyboardType.Uri else KeyboardType.Text),
            trailingIcon = if (secretField) ({
                TextButton(onClick = { reveal = !reveal }) { Text(stringResource(if (reveal) R.string.hide else R.string.show)) }
            }) else null,
            modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp).focusRequester(focus.getValue(field)),
        )
    }

    fun refuse(found: FormError) {
        error = found
        focus.getValue(found.field).requestFocus()
    }

    field(FormField.URL, url, R.string.server_url, { url = it })
    field(FormField.SECRET, secret, R.string.server_secret, { secret = it }, secretField = true)
    OutlinedButton(enabled = !busy, onClick = {
        val found = ConfigForm.urlError(url)
        if (found != null) return@OutlinedButton refuse(found)
        busy = true
        scope.launch {
            val answer = withContext(Dispatchers.IO) { CheckServer.check(url, secret) }
            busy = false
            offered = (answer as? ServerAnswer.Domains)?.domains.orEmpty().map { it.name }
            if (offered.size == 1) domain = offered.single()
            checked = when (answer) {
                is ServerAnswer.Domains -> context.resources.getQuantityString(R.plurals.server_domains, offered.size, offered.size)
                ServerAnswer.SecretRefused -> context.getString(R.string.server_secret_refused)
                ServerAnswer.TooOld -> context.getString(R.string.server_too_old)
                is ServerAnswer.Failed -> context.getString(R.string.server_unchecked, answer.reason)
            }
        }
    }) { Text(stringResource(R.string.check_server)) }
    checked?.let { Text(it, Modifier.padding(vertical = 8.dp)) }
    if (offered.size > 1) Column(Modifier.padding(bottom = 8.dp)) {
        offered.forEach { name -> FilterChip(selected = domain == name, onClick = { domain = name }, label = { Text(name) }) }
    }
    field(FormField.DOMAIN, domain, R.string.domain_name, { domain = it })
    OutlinedTextField(
        value = cache,
        onValueChange = { cache = it },
        label = { Text(stringResource(R.string.cache_limit)) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
    )
    failure?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(bottom = 8.dp)) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Button(enabled = !busy, onClick = {
            val candidate = ServerConfig(url.trim(), secret, domain, cache.trim())
            val found = ConfigForm.validate(candidate)
            if (found != null) return@Button refuse(found)
            busy = true
            scope.launch {
                // A candidate the core refuses never becomes the config; its sentence is shown verbatim.
                failure = withContext(Dispatchers.IO) {
                    try {
                        tsync.prepare()
                        tsync.config.save(candidate, Build.MODEL.orEmpty(), tsync.core::checkConfig)
                    } catch (e: Throwable) {
                        e.message ?: e.toString()
                    }
                }
                busy = false
                if (failure == null) onSaved(candidate)
            }
        }) { Text(saveLabel) }
        if (busy) CircularProgressIndicator(Modifier.padding(start = 16.dp))
    }
}

private data class Storage(val cache: Long?, val pinned: Long?, val staged: Long?)

@Composable
fun SettingsScreen(tsync: Tsync, outer: PaddingValues) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var config by remember { mutableStateOf<ServerConfig?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var storage by remember { mutableStateOf<Storage?>(null) }
    var restart by remember { mutableStateOf(false) }
    var freeing by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        config = withContext(Dispatchers.IO) { tsync.config.read() }
        loaded = true
        storage = withContext(Dispatchers.IO) {
            val stats = runCatching { tsync.client.stats() }.getOrNull()
            Storage(stats?.cacheBytes, stats?.pinnedBytes, runCatching { tsync.client.status().pendingBytes }.getOrNull())
        }
    }
    Screen(stringResource(R.string.destination_settings), outer) { padding ->
        if (!loaded) {
            Loading(padding)
            return@Screen
        }
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp)) {
            Section(R.string.settings_server)
            ServerForm(tsync, config, null, stringResource(R.string.save), onSaved = { saved ->
                // The platform is told either way; the running core keeps the config it booted with.
                tsync.notifyRoots()
                if (saved != config && tsync.boot == Boot.Ready) restart = true
                config = saved
            })

            Section(R.string.settings_storage)
            Text(stringResource(R.string.storage_limit, config?.maxCache.orEmpty()))
            storage?.let {
                fun size(bytes: Long?) = bytes?.let { value -> Formatter.formatFileSize(context, value) } ?: context.getString(R.string.unknown_size)
                Text(stringResource(R.string.storage_cache, size(it.cache)))
                Text(stringResource(R.string.storage_staged, size(it.staged)))
            }
            OutlinedButton(onClick = { freeing = true }, modifier = Modifier.padding(top = 8.dp)) { Text(stringResource(R.string.free_up_space)) }

            Section(R.string.camera_backup)
            BackupControls(tsync)

            Section(R.string.settings_about)
            Text(stringResource(R.string.about_version, BuildConfig.VERSION_NAME))
            Text(stringResource(R.string.about_commit, BuildConfig.COMMIT))
        }
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
    if (freeing) AlertDialog(
        onDismissRequest = { freeing = false },
        title = { Text(stringResource(R.string.free_up_space)) },
        text = { Text(stringResource(R.string.free_up_text)) },
        dismissButton = { TextButton(onClick = { freeing = false }) { Text(stringResource(R.string.cancel)) } },
        confirmButton = {
            TextButton(onClick = {
                freeing = false
                scope.launch {
                    try {
                        val counts = withContext(Dispatchers.IO) { tsync.ask { evict(Parameters.ROOT) } }
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

/** app §11.6: the switch, its two conditions, and "Back up now". */
@Composable
private fun BackupControls(tsync: Tsync) {
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
