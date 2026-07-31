package org.feverdreamtv.tsync

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

/**
 * Milestone 1: prove the daemon runs from nativeLibraryDir and can bind its IPC
 * socket in the app sandbox. That last part is the one thing adb shell cannot
 * test — /data/local/tmp is shell_data_file and the shell domain is denied
 * bind, so every IPC feature is unproven until this screen says otherwise.
 *
 * ponytail: local backend and a plain TextView. Swap in http-proxy and a real
 * status screen once the socket is known to work.
 */
class MainActivity : Activity() {
    private val domain = "test"
    private lateinit var output: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        output = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 11f
            setPadding(24, 24, 24, 24)
        }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(button("Run checks") { thread { runChecks() } })
            addView(button("Stop daemon") {
                stopService(android.content.Intent(this@MainActivity, DaemonService::class.java))
                log("stopped")
            })
            addView(ScrollView(this@MainActivity).apply { addView(output) })
        })

        thread { runChecks() }
    }

    private fun button(label: String, onClick: () -> Unit) =
        Button(this).apply { text = label; setOnClickListener { onClick() } }

    private fun log(line: String) = runOnUiThread { output.append(line + "\n") }

    private fun runChecks() {
        runOnUiThread { output.text = "" }

        val binary = DaemonService.binary(this)
        log("binary: ${binary.absolutePath}")
        log("  exists=${binary.exists()} executable=${binary.canExecute()}")
        if (!binary.canExecute()) {
            log("FAIL: not executable — check extractNativeLibs / useLegacyPackaging")
            return
        }

        writeConfig()

        val (code, out) = DaemonService.run(this, "print-config")
        log("\n\$ tsync print-config (exit $code)\n$out")
        if (code != 0) return

        startForegroundService(android.content.Intent(this, DaemonService::class.java))

        val socket = Ipc.socketPath(filesDir, domain)
        log("waiting for socket: ${socket.absolutePath}")
        val appeared = (1..40).any { Thread.sleep(250); socket.exists() }
        if (!appeared) {
            log("\nFAIL: socket never appeared — see `adb logcat -s tsyncd`")
            return
        }
        log("socket bound ✓  <- the thing adb shell could not do\n")

        probe("status")
        probe("stats")
    }

    private fun probe(action: String) {
        runCatching { Ipc.send(Ipc.socketPath(filesDir, domain), action) }
            .onSuccess { log("$action -> ${summarise(action, it)}\n") }
            .onFailure { log("$action -> FAILED: ${it.message}\n") }
    }

    private fun summarise(action: String, response: JSONObject): String = when (action) {
        "stats" -> response.optJSONObject("server")?.let {
            "frontend=${it.opt("frontend")} pid=${it.opt("pid")} uptime=${it.opt("uptimeSeconds")}s"
        } ?: response.toString()
        else -> response.toString()
    }

    /** A local backend keeps this milestone offline; only the socket is under test. */
    private fun writeConfig() {
        val store = File(filesDir, "store").apply { mkdirs() }
        val config = File(filesDir, ".config/tsync/config.json")
        config.parentFile?.mkdirs()
        config.writeText(
            """
            { "name": "android",
              "domains": [{
                "name": "$domain",
                "versioning": true,
                "symlinks": "skip",
                "frontends": ["headless"],
                "backends": [{ "type": "local", "name": "disk", "role": "main",
                               "path": "${store.absolutePath}" }]
              }] }
            """.trimIndent()
        )
        log("config: ${config.absolutePath}")
    }
}
