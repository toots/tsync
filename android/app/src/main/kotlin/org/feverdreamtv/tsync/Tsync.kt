package org.feverdreamtv.tsync

import android.content.Context
import android.provider.DocumentsContract
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import org.feverdreamtv.tsync.bridge.Native
import org.feverdreamtv.tsync.bridge.NativeCore
import org.feverdreamtv.tsync.core.Client
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

/** What the core told the host (android.md §4.2). */
sealed interface Notice {
    data class Changed(val refs: Set<String>) : Notice
    data object Recovered : Notice
}

/** The process's one owner and everything that hangs off it (app §2). */
class Tsync private constructor(val context: Context) {
    val home: File = context.filesDir
    val config = ConfigStore(home)
    val core: Core = NativeCore
    val client = Client(core)
    val ingest = Ingest(client, IntentStore(home))
    val keepAlive = KeepAlive(context)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val offline = MutableStateFlow(false)
    val latch = OfflineLatch { offline.value = it }
    val notices = MutableSharedFlow<Notice>(extraBufferCapacity = 64)
    val outcomes = MutableSharedFlow<String>(extraBufferCapacity = 16)
    val notificationsWanted = MutableStateFlow(false)

    @Volatile
    var boot: Boot? = null
        private set

    /** The domain this process serves, which a config saved since does not change. */
    @Volatile
    var domain: String = config.read()?.domain.orEmpty()
        private set

    private var prepared = false
    private val observed = ConcurrentHashMap<String, Int>()
    private val refresher = Executors.newSingleThreadScheduledExecutor { Thread(it, "tsync-observed").apply { isDaemon = true } }
    private var refresh: ScheduledFuture<*>? = null

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
        System.loadLibrary("tsyncjni")
        Native.nativeInit(bytes(home.path), bytes(bundle.path), bytes(ingest.intents.stagingDirectory.path))
        Thread(::readNotices, "tsync-notices").apply { isDaemon = true }.start()
        prepared = true
    }

    /** Idempotent; concurrent callers wait for the first. Never on the UI thread. */
    @Synchronized
    fun boot(): Boot {
        if (boot == Boot.Ready) return Boot.Ready
        if (!config.exists()) return Boot.NoConfig.also { boot = it }
        val result = try {
            prepare()
            val name = config.read()?.domain.orEmpty()
            core.boot(name)?.let { Boot.Failed(it) } ?: Boot.Ready.also { domain = name }
        } catch (e: Throwable) {
            Boot.Failed(e.message ?: e.toString())
        }
        boot = result
        if (result == Boot.Ready) resumeSaves()
        return result
    }

    /** The core's verdict on the config on disk, for a boot that failed. */
    fun configRefusal(): String? = try {
        prepare()
        core.checkConfig(config.read()?.domain.orEmpty())
    } catch (e: Throwable) {
        null
    }

    /** app §8.2: after boot, commit what earlier processes left ready. */
    private fun resumeSaves() {
        keepAlive.retain(Work.SAVE)
        scope.launch {
            try {
                ingest.resumeReady { save, result -> Notifications.saveOutcome(this@Tsync, save.staging, save.intent?.target?.name, result) }
                ingest.pending().filter { it.intent == null }.forEach { Notifications.unreadableSave(this@Tsync, it.staging) }
            } finally {
                keepAlive.release(Work.SAVE)
            }
        }
    }

    /** Runs a request, feeding the offline latch (app §5). */
    fun <T> ask(request: Client.() -> T): T = try {
        client.request()
    } catch (e: CoreException) {
        latch.failed(e)
        throw e
    }

    private fun readNotices() {
        while (true) {
            val notice = try {
                JSONObject(Native.nativeNextNotice().toString(Charsets.UTF_8))
            } catch (e: JSONException) {
                continue
            }
            when (notice.optString("event")) {
                "changed" -> {
                    val refs = notice.optJSONArray("refs") ?: continue
                    changed((0 until refs.length()).map { refs.getString(it) }.toSet())
                }
                "recovered" -> {
                    latch.recovered()
                    notices.tryEmit(Notice.Recovered)
                    observed.keys.forEach(::notifyChildren)
                }
            }
        }
    }

    private fun changed(refs: Set<String>) {
        refs.forEach(::notifyChildren)
        notices.tryEmit(Notice.Changed(refs))
    }

    fun notifyChildren(ref: String) {
        context.contentResolver.notifyChange(DocumentsContract.buildChildDocumentsUri(AUTHORITY, ref), null)
    }

    fun notifyRoots() {
        context.contentResolver.notifyChange(DocumentsContract.buildRootsUri(AUTHORITY), null)
    }

    /** app §7.1: listed again every `observed_refresh` for as long as something shows the folder. */
    @Synchronized
    fun observe(ref: String) {
        observed.merge(ref, 1, Int::plus)
        if (refresh == null) {
            val period = Parameters.OBSERVED_REFRESH_MS
            refresh = refresher.scheduleWithFixedDelay(::refreshObserved, period, period, TimeUnit.MILLISECONDS)
        }
    }

    @Synchronized
    fun unobserve(ref: String) {
        observed.computeIfPresent(ref) { _, count -> if (count > 1) count - 1 else null }
        if (observed.isEmpty()) {
            refresh?.cancel(false)
            refresh = null
        }
    }

    private fun refreshObserved() {
        for (ref in observed.keys) {
            try {
                // The owner pulls a folder that is no longer fresh and sends `changed` when it differs.
                latch.listed(ask { listDir(ref, limit = 1) })
            } catch (e: CoreException) {
                if (e.code == Code.NOT_FOUND) changed(setOf(ref))
            } catch (e: Throwable) {
                Log.w(TAG, "observed refresh of $ref failed", e)
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

        fun get(context: Context): Tsync = instance ?: synchronized(this) {
            instance ?: Tsync(context.applicationContext).also { instance = it }
        }
    }
}
