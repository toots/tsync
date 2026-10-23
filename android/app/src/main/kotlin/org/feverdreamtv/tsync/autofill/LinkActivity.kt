package org.feverdreamtv.tsync.autofill

import android.content.Intent
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.IntentCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.LoginRow
import org.feverdreamtv.tsync.ui.TsyncTheme

/**
 * passwords/android §3, *Other logins…*: any login, picked for an app the owner found no site for.
 * The user confirms once; the login then also names the app's `android://` site, and is filled.
 */
class LinkActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val site = intent.getStringExtra(EXTRA_SITE) ?: return done(null)
        val tsync = Tsync.get(this)
        val label = runCatching {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(site.removePrefix("android://"), 0)).toString()
        }.getOrDefault(site)
        setContent { TsyncTheme { Picker(tsync, label, onPick = { link(tsync, site, it) }, onCancel = { done(null) }) } }
    }

    private fun link(tsync: Tsync, site: String, login: LoginRow) {
        tsync.scope.launch {
            val dataset = try {
                if (tsync.boot() != Boot.Ready) null
                else {
                    if (site !in login.urls) tsync.passwords.setSites(login.id, login.urls + site)
                    tsync.vaultChanges.value++
                    val filled = tsync.passwords.fill(site, login.id)
                    val builder = Dataset.Builder()
                    var any = false
                    fun put(key: String, text: String?) {
                        if (text.isNullOrEmpty()) return
                        for (field in ids(key)) {
                            builder.setValue(field, AutofillValue.forText(text))
                            any = true
                        }
                    }
                    put(FillActivity.EXTRA_USERNAME, filled.username)
                    put(FillActivity.EXTRA_PASSWORD, filled.password)
                    if (any) builder.build() else null
                }
            } catch (e: Exception) {
                null
            }
            withContext(Dispatchers.Main) { done(dataset) }
        }
    }

    private fun ids(key: String): List<AutofillId> =
        IntentCompat.getParcelableArrayListExtra(intent, key, AutofillId::class.java).orEmpty()

    private fun done(dataset: Dataset?) {
        if (dataset == null) setResult(RESULT_CANCELED)
        else setResult(RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset))
        finish()
    }

    companion object {
        const val EXTRA_SITE = "org.feverdreamtv.tsync.autofill.LINK_SITE"
    }
}

@Composable
private fun Picker(tsync: Tsync, app: String, onPick: (LoginRow) -> Unit, onCancel: () -> Unit) {
    var filter by remember { mutableStateOf("") }
    var logins by remember { mutableStateOf<List<LoginRow>>(emptyList()) }
    var chosen by remember { mutableStateOf<LoginRow?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(filter) {
        scope.launch {
            logins = withContext(Dispatchers.IO) { runCatching { tsync.passwords.list(filter = filter).logins }.getOrDefault(emptyList()) }
        }
    }
    Column(Modifier.fillMaxSize().padding(top = 32.dp)) {
        OutlinedTextField(
            filter, { filter = it },
            label = { Text(stringResource(R.string.passwords_search)) },
            singleLine = true, modifier = Modifier.fillMaxWidth().padding(16.dp),
        )
        LazyColumn(Modifier.fillMaxSize()) {
            items(logins, key = { it.id }) { login ->
                ListItem(
                    headlineContent = { Text(login.title) },
                    supportingContent = { Text(login.username) },
                    modifier = Modifier.clickable { chosen = login },
                )
            }
        }
    }
    chosen?.let { login ->
        AlertDialog(
            onDismissRequest = { chosen = null },
            text = { Text(stringResource(R.string.autofill_link_confirm, login.title, app)) },
            confirmButton = { TextButton(onClick = { onPick(login) }) { Text(stringResource(R.string.autofill_link_use)) } },
            dismissButton = { TextButton(onClick = { chosen = null; onCancel() }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
