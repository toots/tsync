package org.feverdreamtv.tsync.ui

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PersistableBundle
import android.provider.Settings
import android.view.autofill.AutofillManager
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.PasswordRecords
import org.feverdreamtv.tsync.core.Pull

/** passwords/android §8: list, copy, remove. No password is shown; a copy is marked sensitive. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PasswordsTab(tsync: Tsync, padding: PaddingValues, onLocked: () -> Unit) {
    val context = LocalContext.current
    var filter by remember { mutableStateOf("") }
    var records by remember { mutableStateOf<PasswordRecords?>(null) }
    // android-app §5.1: as in the codes list, the banner waits for a read that asked the server.
    var settled by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var acting by remember { mutableStateOf<Acting?>(null) }
    var autofillOff by remember { mutableStateOf(false) }
    val changes by tsync.vaultChanges.collectAsState()
    val lifecycle = LocalLifecycleOwner.current
    LaunchedEffect(filter, changes) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            autofillOff = context.getSystemService(AutofillManager::class.java)?.hasEnabledAutofillServices() != true
            for (pull in listOf(Pull.BACKGROUND, Pull.DEFAULT)) {
                if (pull == Pull.BACKGROUND && records != null) continue
                val result = attempt { tsync.passwords.list(filter = filter, pull = pull) }
                result.onSuccess { records = it; failure = null; if (pull == Pull.DEFAULT) settled = true }
                    .onFailure { if (pull == Pull.DEFAULT) failure = it.message }
                if ((result.exceptionOrNull() as? CoreException)?.code == Code.LOCKED) {
                    onLocked()
                    return@repeatOnLifecycle
                }
            }
        }
    }
    Column(Modifier.padding(padding)) {
        // §1: the setting is the user's; the row opens it.
        if (autofillOff) ListItem(
            headlineContent = { Text(stringResource(R.string.autofill_turn_on)) },
            supportingContent = { Text(stringResource(R.string.autofill_turn_on_detail)) },
            modifier = Modifier.combinedClickable(onClick = { openAutofillSetting(context) }),
        )
        OutlinedTextField(
            filter, { filter = it },
            label = { Text(stringResource(R.string.passwords_search)) },
            singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        )
        failure?.let { Text(it, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
        val current = records ?: return@Column Loading()
        if (current.outdated && settled) Banner(stringResource(R.string.codes_offline_as_of, age(current.pulledAt)))
        LazyColumn(Modifier.fillMaxSize()) {
            if (current.logins.isEmpty() && current.passkeys.isEmpty() && current.notes.isEmpty()) item { Text(stringResource(R.string.passwords_empty), Modifier.padding(16.dp)) }
            items(current.logins, key = { it.id }) { login ->
                ListItem(
                    headlineContent = { Text(login.title) },
                    supportingContent = { Text(login.username) },
                    modifier = Modifier.combinedClickable(onClick = { acting = Acting(login.id, login.title, login = true, hasCode = login.hasCode) }),
                )
            }
            items(current.notes, key = { it.id }) { note ->
                ListItem(
                    headlineContent = { Text(note.title) },
                    supportingContent = { Text(stringResource(R.string.passwords_note)) },
                    modifier = Modifier.combinedClickable(onClick = { acting = Acting(note.id, note.title, login = false, hasCode = false, note = true) }),
                )
            }
            items(current.passkeys, key = { it.id }) { passkey ->
                ListItem(
                    headlineContent = { Text(passkey.rpId) },
                    supportingContent = { Text(stringResource(R.string.passwords_passkey, passkey.userName)) },
                    modifier = Modifier.combinedClickable(onClick = { acting = Acting(passkey.id, passkey.rpId, login = false, hasCode = false) }),
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
    acting?.let { RecordActions(tsync, it, onDone = { acting = null }) }
}

private data class Acting(val id: String, val name: String, val login: Boolean, val hasCode: Boolean, val note: Boolean = false)

private fun openAutofillSetting(context: Context) {
    val intent = Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE).setData(Uri.parse("package:${context.packageName}"))
    runCatching { context.startActivity(intent) }
}

/** Marked sensitive, so keyboard and clipboard previews hide it; the message names the record. */
private fun copySecret(context: Context, tsync: Tsync, name: String, value: String, copied: Int) {
    val clip = ClipData.newPlainText(name, value)
    clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
    tsync.report(context.getString(copied, name))
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun RecordActions(tsync: Tsync, record: Acting, onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var removing by remember { mutableStateOf(false) }
    var removeSent by remember { mutableStateOf(false) }
    // passwords §2.2: the names of the record's fields; a value is read only when copied.
    var fields by remember { mutableStateOf<List<String>>(emptyList()) }
    LaunchedEffect(record.id) {
        if (record.login || record.note) attempt { tsync.passwords.get(record.id).optJSONArray("fields") }
            .onSuccess { list -> fields = (0 until (list?.length() ?: 0)).mapNotNull { list?.optJSONObject(it)?.optString("name") } }
    }
    fun copyField(name: String) {
        scope.launch {
            attempt {
                val list = tsync.passwords.get(record.id).optJSONArray("fields")
                (0 until (list?.length() ?: 0)).mapNotNull { list?.optJSONObject(it) }.first { it.optString("name") == name }.optString("value")
            }
                .onSuccess { copySecret(context, tsync, name, it, R.string.passwords_field_copied) }
                .onFailure { tsync.report(it.message.orEmpty(), failed = true) }
            onDone()
        }
    }
    fun copy(field: String, copied: Int) {
        scope.launch {
            attempt { tsync.passwords.get(record.id).optString(field) }
                .onSuccess { copySecret(context, tsync, record.name, it, copied) }
                .onFailure { tsync.report(it.message.orEmpty(), failed = true) }
            onDone()
        }
    }
    if (removing) AlertDialog(
        onDismissRequest = onDone,
        text = { Text(stringResource(R.string.passwords_remove_confirm, record.name)) },
        confirmButton = {
            TextButton(enabled = !removeSent, onClick = {
                removeSent = true
                scope.launch {
                    attempt { tsync.passwords.remove(record.id) }.reason()?.let { tsync.report(it, failed = true) }
                    tsync.vaultChanges.value++
                    onDone()
                }
            }) { Text(stringResource(R.string.code_remove)) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.cancel)) } },
    ) else ModalBottomSheet(onDismissRequest = onDone) {
        Column(Modifier.navigationBarsPadding()) {
            Text(record.name, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.titleMedium)
            if (record.login) {
                ListItem(headlineContent = { Text(stringResource(R.string.passwords_copy_username)) }, modifier = Modifier.combinedClickable(onClick = { copy("username", R.string.passwords_username_copied) }))
                ListItem(headlineContent = { Text(stringResource(R.string.passwords_copy_password)) }, modifier = Modifier.combinedClickable(onClick = { copy("password", R.string.passwords_password_copied) }))
                if (record.hasCode) ListItem(headlineContent = { Text(stringResource(R.string.passwords_copy_code)) }, modifier = Modifier.combinedClickable(onClick = { copy("code", R.string.code_copied) }))
            }
            if (record.note) ListItem(headlineContent = { Text(stringResource(R.string.passwords_copy_notes)) }, modifier = Modifier.combinedClickable(onClick = { copy("notes", R.string.passwords_notes_copied) }))
            fields.forEach { name ->
                ListItem(headlineContent = { Text(stringResource(R.string.passwords_copy_field, name)) }, modifier = Modifier.combinedClickable(onClick = { copyField(name) }))
            }
            ListItem(headlineContent = { Text(stringResource(R.string.code_remove)) }, modifier = Modifier.combinedClickable(onClick = { removing = true }))
        }
    }
}
