package org.feverdreamtv.tsync.ui

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.PersistableBundle
import android.view.WindowManager
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import org.feverdreamtv.tsync.core.Code
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.material3.TabRow
import androidx.compose.material3.Tab
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Codes
import org.feverdreamtv.tsync.core.OneTimeCode
import org.feverdreamtv.tsync.core.VaultStatus

/** android-app §10.8: no screenshot or recent-apps thumbnail while a secret can be on screen. */
// ponytail: one count for the app's single activity.
private var secureHolders = 0

/** Pitfall B-8.17: the flag stays while any holder is composed. */
@Composable
fun SecureWindow() {
    val activity = LocalActivity.current ?: return
    DisposableEffect(activity) {
        if (secureHolders++ == 0) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        onDispose {
            if (--secureHolders == 0) activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
}

/** Runs a vault call off the main thread; a refusal comes back as the owner's sentence. */
internal suspend fun <T> attempt(call: () -> T): Result<T> = withContext(Dispatchers.IO) {
    try {
        Result.success(call())
    } catch (e: CoreException) {
        Result.failure(e)
    }
}

internal fun Result<*>.reason(): String? = exceptionOrNull()?.message

/** vault §8.1: the vault's icon, or tsync's glyph in the vault's colour. */
@Composable
fun VaultMark(appearance: org.feverdreamtv.tsync.core.Appearance, modifier: Modifier = Modifier) {
    val icon = remember(appearance.icon) {
        appearance.icon?.let { android.graphics.BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() }
    }
    val size = Modifier.size(24.dp)
    if (icon != null) {
        androidx.compose.foundation.Image(icon, contentDescription = null, modifier = modifier.then(size))
    } else {
        val tint = runCatching { androidx.compose.ui.graphics.Color(android.graphics.Color.parseColor(appearance.color)) }.getOrNull()
        Icon(painterResource(R.drawable.ic_notification), contentDescription = null, modifier = modifier.then(size),
            tint = tint ?: androidx.compose.material3.LocalContentColor.current)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VaultScreen(tsync: Tsync, outer: PaddingValues) {
    SecureWindow()
    var status by remember { mutableStateOf<VaultStatus?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    var menu by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf<Boolean?>(null) }
    var adding by remember { mutableStateOf(false) }
    // android-app §10.8: one tab per extension the domain uses.
    var extensions by remember { mutableStateOf<List<String>>(emptyList()) }
    var tab by rememberSaveable { mutableStateOf("totp") }
    val scope = rememberCoroutineScope()
    val changes by tsync.vaultChanges.collectAsState()
    val lifecycle = LocalLifecycleOwner.current
    fun reload() = generation++
    LaunchedEffect(generation, changes) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            attempt { tsync.vault.status() }
                .onSuccess { status = it; failure = null }
                .onFailure { failure = it.message }
            // passwords/android §1.1: after an unlock, once the status is shown.
            if (status?.state == "unlocked") tsync.warmPasswords()
            attempt { tsync.ask { stats() }.extensions }.onSuccess { extensions = it }
        }
    }
    val unlocked = status?.state == "unlocked"
    Scaffold(
        modifier = Modifier.padding(outer),
        contentWindowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal),
        topBar = {
            TopAppBar(
                navigationIcon = { status?.appearance?.let { VaultMark(it, Modifier.padding(start = 16.dp)) } },
                title = { Text(stringResource(R.string.destination_vault), Modifier.semantics { heading() }) },
                actions = {
                    if (status != null && status?.state != "absent") {
                        IconButton(onClick = { menu = true }) {
                            Icon(painterResource(R.drawable.ic_more), contentDescription = stringResource(R.string.more))
                        }
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        status?.let { DropdownMenuItem(text = { Text(describe(LocalContext.current, it)) }, onClick = {}, enabled = false) }
                        HorizontalDivider()
                        if (unlocked) DropdownMenuItem(text = { Text(stringResource(R.string.vault_lock)) }, onClick = { menu = false; confirm = false })
                        if (status?.enrolled == true) {
                            DropdownMenuItem(text = { Text(stringResource(R.string.vault_forget)) }, onClick = { menu = false; confirm = true })
                        }
                    }
                },
            )
        },
        floatingActionButton = {
            if (unlocked && shownTab(extensions, tab) == "totp") FloatingActionButton(onClick = { adding = true }) {
                Icon(painterResource(R.drawable.ic_add), contentDescription = stringResource(R.string.code_add))
            }
        },
    ) { padding ->
        val current = status
        when {
            failure != null -> Failure(failure!!, padding, onRetry = ::reload)
            current == null -> Loading(padding)
            current.state == "absent" -> Message(stringResource(R.string.vault_absent), padding)
            current.state == "corrupt" -> Message(stringResource(R.string.vault_corrupt), padding)
            current.state == "locked" -> Column(Modifier.padding(padding)) {
                if (current.outdated) Banner(stringResource(R.string.codes_offline_as_of, age(current.pulledAt)))
                if (current.secretKeyReplaced) Banner(stringResource(R.string.vault_secret_key_replaced))
                Column(Modifier.padding(16.dp)) { UnlockForm(tsync, current.enrolled, onUnlocked = ::reload) }
            }
            else -> Column(Modifier.padding(padding)) {
                current.newMachines.forEach { Banner(stringResource(R.string.vault_machine_joined, it)) }
                if (current.newMachines.isNotEmpty()) TextButton(onClick = {
                    scope.launch { attempt { tsync.vault.acknowledgeMachines() }; reload() }
                }, Modifier.padding(horizontal = 8.dp)) { Text(stringResource(R.string.vault_machines_seen)) }
                val tabs = listOf("totp", "passwords").filter { it in extensions }
                if (tabs.size > 1) TabRow(selectedTabIndex = tabs.indexOf(shownTab(extensions, tab)).coerceAtLeast(0)) {
                    tabs.forEach { name ->
                        Tab(selected = shownTab(extensions, tab) == name, onClick = { tab = name }, text = {
                            Text(stringResource(if (name == "totp") R.string.vault_tab_codes else R.string.vault_tab_passwords))
                        })
                    }
                }
                if (shownTab(extensions, tab) == "passwords") PasswordsTab(tsync, PaddingValues(), onLocked = ::reload)
                else CodesList(tsync, PaddingValues(), onLocked = ::reload)
            }
        }
    }
    confirm?.let { forget ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            text = { Text(stringResource(if (forget) R.string.vault_forget_confirm else R.string.vault_lock_confirm)) },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    scope.launch {
                        attempt { tsync.vault.lock(forget) }.reason()?.let { tsync.report(it, failed = true) }
                        reload()
                    }
                }) { Text(stringResource(if (forget) R.string.vault_forget else R.string.vault_lock)) }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    if (adding) AddCodeSheet(tsync, onDismiss = { adding = false; tsync.vaultChanges.value++ })
}

/** The tab asked for when the domain uses its extension, else the one it uses. */
private fun shownTab(extensions: List<String>, asked: String): String =
    if (asked in extensions || "totp" !in extensions && "passwords" !in extensions) asked
    else if ("totp" in extensions) "totp" else "passwords"

private fun describe(context: Context, status: VaultStatus): String {
    val state = context.getString(if (status.state == "unlocked") R.string.vault_state_unlocked else R.string.vault_state_locked)
    val enrolled = context.getString(if (status.enrolled) R.string.vault_state_enrolled else R.string.vault_state_not_enrolled)
    val kept = when (status.cached) {
        "keystore" -> context.getString(R.string.vault_state_keystore)
        "memory" -> context.getString(R.string.vault_state_memory)
        else -> null
    }
    val problem = status.keystoreError?.let { context.getString(R.string.vault_state_keystore_error, it) }
    return listOfNotNull(state, enrolled, kept, problem).joinToString(" · ")
}

@Composable
private fun Message(text: String, padding: PaddingValues) {
    Column(Modifier.fillMaxSize().padding(padding).padding(24.dp), verticalArrangement = Arrangement.Center) {
        Text(text, style = MaterialTheme.typography.bodyLarge)
    }
}

/** A passphrase and, on a phone not yet enrolled, the secret key: masked, paste accepted, no autofill. */
@Composable
fun UnlockForm(tsync: Tsync, enrolled: Boolean, onUnlocked: () -> Unit) {
    var passphrase by remember { mutableStateOf("") }
    var secretKey by remember { mutableStateOf("") }
    var refusal by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.vault_unlock_title), style = MaterialTheme.typography.titleMedium)
        SecretField(passphrase, { passphrase = it }, stringResource(R.string.vault_passphrase), Modifier.fillMaxWidth())
        if (!enrolled) SecretField(
            secretKey, { secretKey = it }, stringResource(R.string.vault_secret_key), Modifier.fillMaxWidth(),
            supportingText = { Text(stringResource(R.string.vault_secret_key_hint)) },
        )
        refusal?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(
            enabled = !busy && passphrase.isNotBlank() && (enrolled || secretKey.isNotBlank()),
            onClick = {
                busy = true
                scope.launch {
                    val result = attempt { tsync.vault.unlock(passphrase, secretKey.takeUnless { enrolled }) }
                    busy = false
                    refusal = result.reason()
                    if (result.isSuccess) onUnlocked()
                }
            },
        ) { Text(stringResource(R.string.vault_unlock)) }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CodesList(tsync: Tsync, padding: PaddingValues, onLocked: () -> Unit) {
    val context = LocalContext.current
    var filter by remember { mutableStateOf("") }
    var codes by remember { mutableStateOf<Codes?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    var elapsed by remember { mutableIntStateOf(0) }
    var acting by remember { mutableStateOf<OneTimeCode?>(null) }
    val changes by tsync.vaultChanges.collectAsState()
    val lifecycle = LocalLifecycleOwner.current
    // The owner computes every code; the app only counts the seconds down and asks again at zero,
    // at each return to the foreground, and after each change it makes (pitfall B-8.18).
    LaunchedEffect(filter, changes) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                val result = attempt { tsync.vault.codes(filter) }
                result.onSuccess { codes = it; failure = null }.onFailure { failure = it.message }
                if ((result.exceptionOrNull() as? CoreException)?.code == Code.LOCKED) {
                    onLocked()
                    return@repeatOnLifecycle
                }
                elapsed = 0
                val wait = codes?.records?.minOfOrNull { it.secondsLeft }?.coerceAtLeast(1) ?: 30
                repeat(wait) { delay(1000); elapsed++ }
            }
        }
    }
    Column(Modifier.padding(padding)) {
        OutlinedTextField(
            filter, { filter = it },
            label = { Text(stringResource(R.string.code_search)) },
            singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
        failure?.let { Text(it, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
        val current = codes ?: return@Column Loading()
        if (current.outdated) Banner(stringResource(R.string.codes_offline_as_of, age(current.pulledAt)))
        LazyColumn(Modifier.fillMaxSize()) {
            if (current.records.isEmpty()) item { Text(stringResource(R.string.codes_empty), Modifier.padding(16.dp)) }
            items(current.records, key = { it.id }) { record ->
                val left = (record.secondsLeft - elapsed).coerceAtLeast(0)
                ListItem(
                    headlineContent = { Text(record.issuer.ifEmpty { record.account }) },
                    supportingContent = {
                        Column {
                            if (record.issuer.isNotEmpty()) Text(record.account)
                            Text(grouped(record.code), style = MaterialTheme.typography.headlineMedium)
                        }
                    },
                    trailingContent = {
                        Text(
                            stringResource(R.string.code_seconds_left, left),
                            color = if (left <= 5) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    },
                    modifier = Modifier.combinedClickable(
                        onClick = { copy(context, tsync, record) },
                        onLongClick = { acting = record },
                    ),
                )
            }
            if (current.corrupt > 0) item {
                Text(
                    context.resources.getQuantityString(R.plurals.codes_corrupt, current.corrupt, current.corrupt),
                    Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
    acting?.let { CodeActions(tsync, it, onDone = { acting = null; tsync.vaultChanges.value++ }) }
}

private fun grouped(code: String) = code.chunked(3).joinToString(" ")

/** Marked sensitive, so keyboard and clipboard previews hide it; the message names the record. */
private fun copy(context: Context, tsync: Tsync, record: OneTimeCode) {
    val clip = ClipData.newPlainText(record.issuer, record.code)
    clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
    tsync.report(context.getString(R.string.code_copied, record.issuer.ifEmpty { record.account }))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CodeActions(tsync: Tsync, record: OneTimeCode, onDone: () -> Unit) {
    var renaming by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(false) }
    var removeSent by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val name = record.issuer.ifEmpty { record.account }
    when {
        renaming -> {
            var issuer by remember { mutableStateOf(record.issuer) }
            var account by remember { mutableStateOf(record.account) }
            var refusal by remember { mutableStateOf<String?>(null) }
            var busy by remember { mutableStateOf(false) }
            AlertDialog(
                onDismissRequest = onDone,
                title = { Text(stringResource(R.string.action_rename)) },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(issuer, { issuer = it }, label = { Text(stringResource(R.string.code_issuer)) }, singleLine = true)
                        OutlinedTextField(account, { account = it }, label = { Text(stringResource(R.string.code_account)) }, singleLine = true)
                        refusal?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                },
                confirmButton = {
                    TextButton(enabled = !busy, onClick = {
                        busy = true
                        scope.launch {
                            val result = attempt { tsync.vault.rename(record.id, issuer.trim(), account.trim()) }
                            busy = false
                            refusal = result.reason()
                            if (result.isSuccess) onDone()
                        }
                    }) { Text(stringResource(R.string.save)) }
                },
                dismissButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.cancel)) } },
            )
        }
        removing -> AlertDialog(
            onDismissRequest = onDone,
            text = { Text(stringResource(R.string.code_remove_confirm, name)) },
            confirmButton = {
                TextButton(enabled = !removeSent, onClick = {
                    removeSent = true
                    scope.launch {
                        attempt { tsync.vault.remove(record.id) }.reason()?.let { tsync.report(it, failed = true) }
                        onDone()
                    }
                }) { Text(stringResource(R.string.code_remove)) }
            },
            dismissButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.cancel)) } },
        )
        else -> ModalBottomSheet(onDismissRequest = onDone) {
            Column(Modifier.navigationBarsPadding()) {
                Text(name, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.titleMedium)
                ListItem(headlineContent = { Text(stringResource(R.string.action_rename)) }, modifier = Modifier.combinedClickable(onClick = { renaming = true }))
                ListItem(headlineContent = { Text(stringResource(R.string.code_remove)) }, modifier = Modifier.combinedClickable(onClick = { removing = true }))
            }
        }
    }
}

private fun playServices(context: Context) =
    GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS

/** Google's code scanner: no camera permission, QR only. */
private fun scan(context: Context, onText: (String) -> Unit, onFailure: (String) -> Unit) {
    val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    GmsBarcodeScanning.getClient(context, options).startScan()
        .addOnSuccessListener { barcode -> barcode.rawValue?.let(onText) }
        .addOnFailureListener {
            onFailure((it.message ?: context.getString(R.string.code_scan_failed)) + "\n\n" + context.getString(R.string.code_scan_camera))
        }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun AddCodeSheet(tsync: Tsync, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var entering by remember { mutableStateOf(false) }
    var outcome by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    fun adding(call: () -> Any) {
        if (busy) return
        busy = true
        scope.launch {
            val result = attempt(call)
            busy = false
            outcome = result.reason() ?: context.getString(R.string.code_added)
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            val text = withContext(Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
            } ?: return@launch
            attempt { tsync.vault.import(text) }
                .onSuccess { imported ->
                    outcome = buildString {
                        append(context.getString(R.string.code_imported, imported.added, imported.already, imported.refused.size))
                        imported.refused.forEach { append("\n").append(context.getString(R.string.code_import_refused, it.line, it.reason)) }
                    }
                }
                .onFailure { outcome = it.message }
        }
    }
    when {
        outcome != null -> AlertDialog(
            onDismissRequest = onDismiss,
            text = { Text(outcome!!, Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
        )
        entering -> EnterCode(onDismiss, busy) { secret, issuer, account ->
            adding { tsync.vault.add(secret, issuer, account) }
        }
        else -> ModalBottomSheet(onDismissRequest = onDismiss) {
            Column(Modifier.navigationBarsPadding()) {
                val scanner = playServices(context)
                ListItem(
                    headlineContent = { Text(stringResource(R.string.code_scan)) },
                    supportingContent = if (scanner) null else ({ Text(stringResource(R.string.code_scan_unavailable)) }),
                    modifier = Modifier.combinedClickable(enabled = scanner, onClick = {
                        scan(context, { text -> adding { tsync.vault.add(text) } }, { outcome = it })
                    }),
                )
                ListItem(headlineContent = { Text(stringResource(R.string.code_enter)) }, modifier = Modifier.combinedClickable(onClick = { entering = true }))
                ListItem(
                    headlineContent = { Text(stringResource(R.string.code_import)) },
                    modifier = Modifier.combinedClickable(onClick = { picker.launch(arrayOf("text/*")) }),
                )
            }
        }
    }
}

@Composable
private fun EnterCode(onDismiss: () -> Unit, busy: Boolean, onSubmit: (String, String, String) -> Unit) {
    var issuer by remember { mutableStateOf("") }
    var account by remember { mutableStateOf("") }
    var secret by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.code_enter)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(issuer, { issuer = it }, label = { Text(stringResource(R.string.code_issuer)) }, singleLine = true)
                OutlinedTextField(account, { account = it }, label = { Text(stringResource(R.string.code_account)) }, singleLine = true)
                SecretField(
                    secret, { secret = it }, stringResource(R.string.code_secret),
                    supportingText = { Text(stringResource(R.string.code_secret_hint)) },
                )
            }
        },
        confirmButton = {
            TextButton(enabled = !busy && secret.isNotBlank(), onClick = { onSubmit(secret, issuer, account) }) { Text(stringResource(R.string.add)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** An `otpauth://` link handed over by another app: nothing is added before Add (android-app §10.8). */
@Composable
fun CodeLinkSheet(tsync: Tsync, link: String, onDone: () -> Unit) {
    SecureWindow()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf<VaultStatus?>(null) }
    var unreachable by remember { mutableStateOf<String?>(null) }
    var checked by remember { mutableStateOf(false) }
    var generation by remember { mutableIntStateOf(0) }
    var refusal by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(generation) {
        val result = attempt { tsync.vault.status() }
        status = result.getOrNull()
        unreachable = result.reason()
        checked = true
    }
    val name = remember(link) { linkName(link) }
    val current = status
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(stringResource(R.string.code_link_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when {
                    !checked -> Text(stringResource(R.string.loading))
                    unreachable != null -> Text(unreachable!!)
                    current == null -> Text(stringResource(R.string.vault_not_used))
                    current.state == "absent" -> Text(stringResource(R.string.vault_absent))
                    current.state == "corrupt" -> Text(stringResource(R.string.vault_corrupt))
                    current.state == "locked" -> UnlockForm(tsync, current.enrolled, onUnlocked = {
                        generation++
                        tsync.vaultChanges.value++
                    })
                    else -> Text(stringResource(R.string.code_link_add, name))
                }
                refusal?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            if (current?.state == "unlocked") TextButton(enabled = !busy, onClick = {
                busy = true
                scope.launch {
                    val result = attempt { tsync.vault.add(link) }
                    busy = false
                    refusal = result.reason()
                    if (result.isSuccess) {
                        tsync.vaultChanges.value++
                        tsync.report(context.getString(R.string.code_added))
                        onDone()
                    }
                }
            }) { Text(stringResource(R.string.add)) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.cancel)) } },
    )
}

/** "Issuer — account" from the link's label and issuer parameter, for the confirmation only. */
private fun linkName(link: String): String {
    val uri = Uri.parse(link)
    val label = uri.path.orEmpty().removePrefix("/")
    val issuer = uri.getQueryParameter("issuer") ?: label.substringBefore(':', "")
    val account = label.substringAfter(':')
    return listOf(issuer, account).filter { it.isNotBlank() }.distinct().joinToString(" — ").ifEmpty { link.substringBefore('?') }
}

/** security-model §10.6: masked, with an icon that shows the value while on; off each time it is shown. */
@Composable
fun SecretField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    supportingText: (@Composable () -> Unit)? = null,
) {
    var shown by remember { mutableStateOf(false) }
    OutlinedTextField(
        value, onValueChange,
        label = { Text(label) },
        supportingText = supportingText,
        visualTransformation = if (shown) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            keyboardType = KeyboardType.Password,
        ),
        trailingIcon = {
            IconButton(onClick = { shown = !shown }) {
                Icon(
                    painterResource(if (shown) R.drawable.ic_visibility_off else R.drawable.ic_visibility),
                    contentDescription = stringResource(if (shown) R.string.secret_hide else R.string.secret_show),
                )
            }
        },
        singleLine = true,
        modifier = modifier,
    )
}
