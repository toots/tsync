@file:OptIn(ExperimentalMaterial3Api::class)

package org.feverdreamtv.tsync.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.IntentCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Item
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.ServerConfig

class MainActivity : ComponentActivity() {
    private var shared by mutableStateOf<List<Uri>?>(null)
    private var activityRequests by mutableIntStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        accept(intent)
        setContent {
            TsyncTheme {
                App(shared, activityRequests, onShareDone = ::finish)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        accept(intent)
    }

    private fun accept(intent: Intent) {
        if (intent.getBooleanExtra(EXTRA_SHOW_ACTIVITY, false)) activityRequests++
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return
        val streams = streams(intent)
        val refusal = when {
            streams.isEmpty() -> R.string.share_only_files
            !Tsync.get(this).config.exists() -> R.string.share_not_set_up
            else -> null
        }
        if (refusal == null) {
            shared = streams
        } else {
            Toast.makeText(this, refusal, Toast.LENGTH_LONG).show()
            finish()
        }
    }

    private fun streams(intent: Intent): List<Uri> =
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        } else {
            listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
        }

    companion object {
        const val EXTRA_SHOW_ACTIVITY = "org.feverdreamtv.tsync.SHOW_ACTIVITY"
    }
}

@Composable
fun TsyncTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}

private data class Started(val boot: Boot, val refusal: String?, val config: ServerConfig?)

@Composable
private fun App(shared: List<Uri>?, activityRequests: Int, onShareDone: () -> Unit) {
    val context = LocalContext.current
    val tsync = remember { Tsync.get(context) }
    var started by remember { mutableStateOf<Started?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    LaunchedEffect(attempt) {
        started = withContext(Dispatchers.IO) {
            val boot = tsync.boot()
            // A config the core refuses leads back to Setup with its reason; nothing is deleted.
            val refusal = if (boot is Boot.Failed) tsync.configRefusal() else null
            Started(boot, refusal, tsync.config.read())
        }
    }
    NotificationPermission(tsync)
    val state = started
    when {
        state == null -> Screen(stringResource(R.string.app_name)) { Loading(it) }
        state.boot == Boot.NoConfig -> SetupScreen(null, null, onConnected = { started = null; attempt++ })
        state.boot is Boot.Failed && state.refusal != null ->
            SetupScreen(state.config, state.refusal, onConnected = { started = null; attempt++ })
        state.boot is Boot.Failed -> Screen(stringResource(R.string.app_name)) {
            Failure(state.boot.reason, it, onRetry = { started = null; attempt++ })
        }
        shared != null -> SaveTarget(tsync, shared, onShareDone)
        else -> Main(tsync, activityRequests)
    }
}

@Composable
private fun NotificationPermission(tsync: Tsync) {
    val wanted by tsync.notificationsWanted.collectAsState()
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    val context = LocalContext.current
    LaunchedEffect(wanted) {
        if (!wanted || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return@LaunchedEffect
        tsync.notificationsWanted.value = false
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }
}

enum class Destination(val label: Int, val icon: Int) {
    FILES(R.string.destination_files, R.drawable.ic_folder),
    ACTIVITY(R.string.destination_activity, R.drawable.ic_activity),
    SETTINGS(R.string.destination_settings, R.drawable.ic_settings),
}

data class Crumb(val ref: String, val name: String)

private val trailSaver = listSaver<SnapshotStateList<Crumb>, String>(
    save = { trail -> trail.flatMap { listOf(it.ref, it.name) } },
    restore = { saved -> saved.chunked(2).map { Crumb(it[0], it[1]) }.toMutableStateList() },
)

@Composable
fun rememberTrail(rootName: String): SnapshotStateList<Crumb> =
    rememberSaveable(saver = trailSaver) { listOf(Crumb(Parameters.ROOT, rootName)).toMutableStateList() }

@Composable
private fun Main(tsync: Tsync, activityRequests: Int) {
    var destination by rememberSaveable { mutableStateOf(Destination.FILES) }
    val trail = rememberTrail(tsync.domain)
    var moving by remember { mutableStateOf<Item?>(null) }
    val snackbar = remember { SnackbarHostState() }
    val lifecycle = LocalLifecycleOwner.current
    LaunchedEffect(activityRequests) { if (activityRequests > 0) destination = Destination.ACTIVITY }
    LaunchedEffect(Unit) {
        // Outcomes are shown here only while the screen is; otherwise they become notifications.
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { tsync.outcomes.collect { snackbar.showSnackbar(it) } }
    }
    BackHandler(enabled = destination != Destination.FILES) { destination = Destination.FILES }
    Scaffold(
        contentWindowInsets = WindowInsets(0),
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            if (moving == null) NavigationBar {
                for (entry in Destination.entries) NavigationBarItem(
                    selected = destination == entry,
                    onClick = { destination = entry },
                    icon = { Icon(painterResource(entry.icon), contentDescription = null) },
                    label = { Text(stringResource(entry.label)) },
                )
            }
        },
    ) { bars ->
        val item = moving
        when {
            destination == Destination.FILES && item != null -> MoveTarget(tsync, item, bars, onDone = { moving = null })
            destination == Destination.FILES -> FilesScreen(tsync, FilesMode.Browse, trail, bars, onMove = { moving = it })
            destination == Destination.ACTIVITY -> ActivityScreen(tsync, bars)
            else -> SettingsScreen(tsync, bars)
        }
    }
}

/** One screen: a title bar over content, edge to edge, inside whatever bars surround it. */
@Composable
fun Screen(
    title: String,
    outer: PaddingValues = PaddingValues(),
    onBack: (() -> Unit)? = null,
    bottomBar: @Composable () -> Unit = {},
    floatingActionButton: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        modifier = Modifier.padding(outer),
        contentWindowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal),
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.semantics { heading() }) },
                navigationIcon = {
                    if (onBack != null) IconButton(onClick = onBack) {
                        Icon(painterResource(R.drawable.ic_back), contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
        bottomBar = bottomBar,
        floatingActionButton = floatingActionButton,
        content = content,
    )
}

@Composable
fun Loading(padding: PaddingValues = PaddingValues()) {
    Column(
        Modifier.fillMaxSize().padding(padding),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator()
        Text(stringResource(R.string.loading), Modifier.padding(top = 16.dp))
    }
}

@Composable
fun Failure(reason: String, padding: PaddingValues = PaddingValues(), onRetry: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(painterResource(R.drawable.ic_cloud), contentDescription = null)
        Text(reason, Modifier.padding(vertical = 16.dp), style = MaterialTheme.typography.bodyLarge)
        Button(onClick = onRetry) { Text(stringResource(R.string.retry)) }
    }
}
