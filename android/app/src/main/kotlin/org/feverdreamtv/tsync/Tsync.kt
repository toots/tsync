package org.feverdreamtv.tsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.provider.DocumentsContract
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import org.feverdreamtv.tsync.bridge.Keystore
import org.feverdreamtv.tsync.bridge.Native
import org.feverdreamtv.tsync.bridge.NativeCore
import org.feverdreamtv.tsync.core.Client
import org.feverdreamtv.tsync.core.Vault
import org.feverdreamtv.tsync.core.Passwords
import org.feverdreamtv.tsync.core.Pull
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.ConfigStore
import org.feverdreamtv.tsync.core.Core
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Ingest
import org.feverdreamtv.tsync.core.IntentStore
import org.feverdreamtv.tsync.core.KeepAliveCounter.Work
import org.feverdreamtv.tsync.core.OfflineLatch
import org.feverdreamtv.tsync.core.Parameters
import org.feverdreamtv.tsync.core.TrustBundle
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

sealed interface Boot {
    data object NoConfig : Boot
    data class Failed(val reason: String) : Boot
    data object Ready : Boot
}

/** What the core told the host (android.md §4.2), naming the domain it is about. */
sealed interface Notice {
    val domain: String

    data class Changed(override val domain: String, val refs: Set<String>) : Notice
    data class Recovered(override val domain: String) : Notice
}

/** One configured domain and everything that hangs off its owner (app §2). Boots on first use. */
class Served internal constructor(val name: String, private val tsync: Tsync) {
    val core: Core = NativeCore(name)
    val client = Client(core)
    val vault = Vault(client)
    val passwords = Passwords(client)
    val offline = MutableStateFlow(false)
    val latch = OfflineLatch { offline.value = it }

    @Volatile
    var boot: Boot? = null
        internal set

    /** Idempotent; concurrent callers wait for the first. Never on the UI thread. */
    fun boot(): Boot = tsync.boot(this)

    /**
     * Runs a request, booting the domain first and feeding its offline latch (app §5). Never on
     * the UI thread. @throws CoreException with the boot failure
     */
    fun <T> ask(request: Client.() -> T): T {
        when (val boot = boot()) {
            Boot.Ready -> {}
            Boot.NoConfig -> throw CoreException(Code.NOT_FOUND, "$name is not configured")
            is Boot.Failed -> throw CoreException(Code.INTERNAL, boot.reason)
        }
        return try {
            client.request()
        } catch (e: CoreException) {
            latch.failed(e)
            throw e
        }
    }

    fun documentId(ref: String): String = Tsync.documentId(name, ref)
}

/** The process's owners, one per domain booted, and what they share (app §2). */
class Tsync private constructor(val context: Context) {
    val home: File = context.filesDir
    val config = ConfigStore(home)
    private val served = ConcurrentHashMap<String, Served>()

    /** Bumped by every vault change the app makes, so each vault screen asks again (pitfall B-8.18). */
    val vaultChanges = MutableStateFlow(0)
    val ingest = Ingest(IntentStore(home), { config.names().firstOrNull() }) { domain(it).ask { this } }
    val keepAlive = KeepAlive(context)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val notices = MutableSharedFlow<Notice>(extraBufferCapacity = 64)
    val outcomes = MutableSharedFlow<String>(extraBufferCapacity = 16)
    val notificationsWanted = MutableStateFlow(false)

    /** The domains booted so far, for screens that follow them. */
    val bootedNames = MutableStateFlow<Set<String>>(emptySet())
    private val vaultPrefs = context.getSharedPreferences("vault", Context.MODE_PRIVATE)

    private var prepared = false
    private var watching = false
    private val observed = ConcurrentHashMap<String, Int>()
    private val refresher = Executors.newSingleThreadScheduledExecutor { Thread(it, "tsync-observed").apply { isDaemon = true } }
    private var refresh: ScheduledFuture<*>? = null

    /** The one object of [name], configured or not. */
    fun domain(name: String): Served = served.computeIfAbsent(name) { Served(it, this) }

    /** The configured domains, in config order. */
    fun domains(): List<Served> = config.names().map(::domain)

    fun booted(): List<Served> = domains().filter { it.boot == Boot.Ready }

    /**
     * Once per process, before the core is used: local recovery, the trust bundle (app §4), the
     * library, and the notice thread.
     */
    @Synchronized
    fun prepare() {
        if (prepared) return
        ingest.intents.recover()
        val bundle = File(home, "ca-bundle.pem")
        TrustBundle.refresh(bundle, listOf(File("/apex/com.android.conscrypt/cacerts"), File("/system/etc/security/cacerts")))
        Keystore.directory = File(context.noBackupFilesDir, "vault")
        System.loadLibrary("tsyncjni")
        Native.nativeInit(bytes(home.path), bytes(bundle.path), bytes(ingest.intents.stagingDirectory.path))
        Thread(::readNotices, "tsync-notices").apply { isDaemon = true }.start()
        prepared = true
        ingest.pending().filter { it.intent == null }.forEach { Notifications.unreadableSave(this, it.staging) }
    }

    internal fun boot(domain: Served): Boot = synchronized(domain) {
        domain.boot?.takeIf { it == Boot.Ready }?.let { return it }
        // Not cached: a domain the config names later boots then.
        if (domain.name !in config.names()) return Boot.NoConfig
        val result = try {
            prepare()
            domain.core.boot(domain.name)?.let { Boot.Failed(it) } ?: Boot.Ready
        } catch (e: Throwable) {
            Boot.Failed(e.message ?: e.toString())
        }
        domain.boot = result
        if (result == Boot.Ready) {
            bootedNames.value += domain.name
            resumeSaves(domain.name)
            watchScreen()
        }
        result
    }

    /** Fetches and opens a setup link (setup-link §6.3), which needs no domain booted. */
    fun setupLink(link: String): String {
        prepare()
        return NativeCore("").setupLink(link)
    }

    /** The core's verdict on a config on disk that names no domain it can read. */
    fun configRefusal(): String? = try {
        prepare()
        config.names().firstOrNull()?.let { domain(it).core.checkConfig(it) }
    } catch (e: Throwable) {
        e.message ?: e.toString()
    }

    /** app §2: the domains that had a vault when last asked. */
    fun vaultDomains(): Set<String> = vaultPrefs.getStringSet("domains", null).orEmpty()

    /**
     * The domains whose vaults a reader asks, in config order, each booted: those of
     * [vaultDomains], and any other already booted, which may have one.
     */
    fun vaults(): List<Served> {
        val known = vaultDomains()
        return domains().filter { (it.name in known || it.boot == Boot.Ready) && it.boot() == Boot.Ready }
    }

    /** The vault domains using [extension], in config order (extensions README §6.1). */
    fun using(extension: String): List<Served> = vaults().filter { extension in extensions(it) }

    /** The extensions a booted [domain] uses here (05 §2.1 rule 5); none when it cannot say. */
    fun extensions(domain: Served): List<String> = try {
        domain.client.stats().extensions
    } catch (e: CoreException) {
        emptyList()
    }

    /** Records whether [domain]'s `vault_status` answered, so later readers boot it (app §2). */
    fun noteVault(domain: String, has: Boolean) {
        val known = vaultDomains()
        if ((domain in known) == has) return
        vaultPrefs.edit().putStringSet("domains", if (has) known + domain else known - domain).apply()
    }

    /** vault §6.2: reported while the process lives; a process that is gone holds no K to lock. */
    @Synchronized
    private fun watchScreen() {
        if (watching) return
        watching = true
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                scope.launch {
                    for (domain in booted()) {
                        try {
                            domain.vault.screenLocked()
                        } catch (e: CoreException) {
                            // No vault, or none to lock: nothing to report.
                        }
                    }
                    vaultChanges.value += 1
                }
            }
        }
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
    }

    /** app §8.2: after a domain boots, commit what earlier processes left ready for it. */
    private fun resumeSaves(domain: String) {
        keepAlive.retain(Work.SAVE)
        scope.launch {
            try {
                ingest.resumeReady(domain) { save, result -> Notifications.saveOutcome(this@Tsync, save.staging, save.intent?.target?.name, result) }
            } finally {
                keepAlive.release(Work.SAVE)
            }
        }
    }

    /**
     * passwords/android §1.1: a background listing starts the fetch of the record bodies the
     * phone lacks, outside the vault's locks, so a form that asks later is answered from what
     * the phone holds. A domain not using passwords, or a locked vault, has nothing to fetch.
     */
    fun warmPasswords() {
        if (!warming.compareAndSet(false, true)) return
        scope.launch {
            try {
                for (domain in vaults()) {
                    try {
                        domain.passwords.list(pull = Pull.BACKGROUND)
                    } catch (e: CoreException) {
                        // Nothing to warm, or nothing reachable: the next form asks again.
                    }
                }
            } finally {
                warming.set(false)
            }
        }
    }

    /** One warm-up at a time. */
    private val warming = java.util.concurrent.atomic.AtomicBoolean(false)

    private fun readNotices() {
        while (true) {
            val notice = try {
                JSONObject(Native.nativeNextNotice().toString(Charsets.UTF_8))
            } catch (e: JSONException) {
                continue
            }
            val domain = notice.optString("domain")
            when (notice.optString("event")) {
                "changed" -> {
                    val refs = notice.optJSONArray("refs") ?: continue
                    changed(domain, (0 until refs.length()).map { refs.getString(it) }.toSet())
                }
                "recovered" -> {
                    domain(domain).latch.recovered()
                    vaultChanges.value++
                    notices.tryEmit(Notice.Recovered(domain))
                    observed.keys.filter { split(it)?.first == domain }.forEach(::notifyChildren)
                }
            }
        }
    }

    private fun changed(domain: String, refs: Set<String>) {
        refs.forEach { notifyChildren(documentId(domain, it)) }
        notices.tryEmit(Notice.Changed(domain, refs))
    }

    fun notifyChildren(documentId: String) {
        context.contentResolver.notifyChange(DocumentsContract.buildChildDocumentsUri(AUTHORITY, documentId), null)
    }

    fun notifyRoots() {
        context.contentResolver.notifyChange(DocumentsContract.buildRootsUri(AUTHORITY), null)
    }

    /** app §7.1: listed again every `observed_refresh` for as long as something shows the folder. */
    @Synchronized
    fun observe(documentId: String) {
        observed.merge(documentId, 1, Int::plus)
        if (refresh == null) {
            val period = Parameters.OBSERVED_REFRESH_MS
            refresh = refresher.scheduleWithFixedDelay(::refreshObserved, period, period, TimeUnit.MILLISECONDS)
        }
    }

    @Synchronized
    fun unobserve(documentId: String) {
        observed.computeIfPresent(documentId) { _, count -> if (count > 1) count - 1 else null }
        if (observed.isEmpty()) {
            refresh?.cancel(false)
            refresh = null
        }
    }

    private fun refreshObserved() {
        for (id in observed.keys) {
            val (name, ref) = split(id) ?: continue
            val domain = domain(name)
            if (domain.boot != Boot.Ready) continue
            try {
                // The owner pulls a folder that is no longer fresh and sends `changed` when it differs.
                domain.latch.listed(domain.ask { listDir(ref, limit = 1) })
            } catch (e: CoreException) {
                if (e.code == Code.NOT_FOUND) changed(name, setOf(ref))
            } catch (e: Throwable) {
                Log.w(TAG, "observed refresh of $id failed", e)
            }
        }
    }

    /** Says how something ended: on screen while a screen listens, else as a notification. */
    fun report(text: String, failed: Boolean = false) {
        if (outcomes.subscriptionCount.value > 0) {
            outcomes.tryEmit(text)
        } else if (failed) {
            Notifications.problem(this, text, context.getString(R.string.app_name), text)
        } else {
            Notifications.outcome(this, text, context.getString(R.string.app_name), text)
        }
    }

    private fun bytes(text: String) = text.toByteArray(Charsets.UTF_8)

    companion object {
        const val AUTHORITY = "org.feverdreamtv.tsync.documents"
        const val TAG = "tsync"

        @Volatile
        private var instance: Tsync? = null

        /** app §7: `<domain>/<reference>`; a domain name holds no `/`. */
        fun documentId(domain: String, ref: String): String = "$domain/$ref"

        fun split(documentId: String): Pair<String, String>? {
            val slash = documentId.indexOf('/')
            return if (slash <= 0) null else documentId.substring(0, slash) to documentId.substring(slash + 1)
        }

        fun get(context: Context): Tsync = instance ?: synchronized(this) {
            instance ?: Tsync(context.applicationContext).also { instance = it }
        }
    }
}
