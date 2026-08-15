package org.feverdreamtv.tsync

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowInsets
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.ArrayAdapter
import android.widget.AutoCompleteTextView
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import kotlin.concurrent.thread

/**
 * Two states, not two screens: setup when there is no config, status once there
 * is. Everything shown on the status screen is `tsync status` verbatim, so it
 * cannot drift from what the desktop reports.
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Config.exists(this)) {
            TsyncProvider.notifyRootsChanged(this)
            showStatus()
        } else showSetup()
    }

    // ── Setup ────────────────────────────────────────────────────────────────

    private fun showSetup() {
        val existing = Config.load(this)
        // Free text until "Check server" fills the dropdown: the server may be
        // unreachable from here, and a typed name still has to be allowed then.
        val domain = AutoCompleteTextView(this).apply {
            hint = "e.g. Jellyfin Media"
            setText(existing?.domain ?: "")
            setSingleLine()
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
            setOnClickListener { showDropDown() }
        }
        val url = field("https://tsync.example.org", existing?.url ?: "")
        val secret = field("Shared secret", existing?.secret ?: "", secret = true)
        val cache = field("Cache limit", existing?.maxCache ?: "2G")
        val error = TextView(this).apply { setPadding(0, 8, 0, 8) }

        val check = Button(this).apply {
            text = "Check server"
            setOnClickListener {
                val at = url.text.toString().trim()
                val with = secret.text.toString().trim()
                isEnabled = false
                error.text = "checking…"
                thread {
                    val found = Server.domains(at, with)
                    runOnUiThread {
                        isEnabled = true
                        found.onFailure { error.text = "Cannot use this server: ${it.message}" }
                        found.onSuccess { names ->
                            domain.setAdapter(ArrayAdapter(
                                this@MainActivity, android.R.layout.simple_list_item_1, names))
                            error.text = when {
                                names.isEmpty() -> "Server reached, but it serves this secret no domain"
                                names.size == 1 -> "Server reached, serving “${names[0]}”"
                                else -> "Server reached — pick a domain"
                            }
                            if (names.size == 1) domain.setText(names[0]) else domain.showDropDown()
                        }
                    }
                }
            }
        }

        val save = Button(this).apply {
            text = "Save and start"
            setOnClickListener {
                val settings = Config.Settings(
                    domain.text.toString().trim(),
                    url.text.toString().trim(),
                    secret.text.toString().trim(),
                    cache.text.toString().trim().ifBlank { "2G" }
                )
                Config.validate(settings)?.let { problem ->
                    // Put the message on the field it belongs to and scroll
                    // there: with the keyboard up the form scrolls, and an
                    // error at the bottom can refer to a field off the top.
                    val culprit = when (problem.field) {
                        Config.Field.DOMAIN -> domain
                        Config.Field.URL -> url
                        Config.Field.SECRET -> secret
                    }
                    error.text = ""
                    culprit.error = problem.message
                    culprit.requestFocus()
                    return@setOnClickListener
                }

                Config.save(this@MainActivity, settings)
                // The daemon is the authority on whether its own config parses;
                // anything else here would be a second implementation that drifts.
                val (code, output) = DaemonService.run(this@MainActivity, "config")
                if (code != 0) {
                    error.text = "tsync rejected the config:\n$output"
                    return@setOnClickListener
                }
                startForegroundService(Intent(this@MainActivity, DaemonService::class.java))
                // The root's id and title come from the config, so the picker
                // is holding a stale answer until it re-queries.
                TsyncProvider.notifyRootsChanged(this@MainActivity)
                showStatus()
            }
        }

        setContentViewInsetAware(ScrollView(this).apply {
            addView(column {
                addView(heading("Connect to your tsync server"))
                addView(label("Domain name"));   addView(domain)
                addView(label("Server URL"));    addView(url)
                addView(label("Shared secret")); addView(secret)
                addView(check)
                addView(label("Cache limit"));   addView(cache)
                addView(error)
                addView(save)
            })
        })
    }

    // ── Status ───────────────────────────────────────────────────────────────

    private fun showStatus() {
        val output = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 10f
        }

        // Wait until the daemon answers, not until its socket file is there:
        // the socket lives on the filesystem, so the file outlives the process
        // that bound it. Android kills this app's process while it is away and
        // the daemon, its child, goes too — leaving a path that exists and
        // listens to nothing, which is what made a restarting daemon report as
        // absent.
        fun refresh() = thread {
            runOnUiThread { output.text = "starting…" }
            val socket = Ipc.socketPath(filesDir, Config.load(this)?.domain ?: "")
            var waited = 0
            var answering = false
            while (waited++ < 40 && !answering) {
                answering = runCatching { Ipc.send(socket, "status") }.isSuccess
                if (!answering) Thread.sleep(250)
            }
            val (_, text) = DaemonService.run(this, "status")
            // A walk creates each folder before fetching what is inside it, so
            // mid-sync a directory that looks empty is not one.
            val syncing =
                if (DaemonService.syncRunning)
                    "full sync running — folders fill in as it walks\n\n"
                else ""
            runOnUiThread {
                output.text = syncing + text.ifBlank {
                    if (answering) "daemon is up but returned nothing"
                    else "daemon did not start — check `adb logcat -s tsyncd`"
                }
            }
        }

        setContentViewInsetAware(column {
            addView(row {
                addView(Button(this@MainActivity).apply {
                    text = "Refresh"; setOnClickListener { refresh() }
                })
                val sync = Button(this@MainActivity)
                addView(sync.apply {
                    text = "Sync"
                    setOnClickListener {
                        sync.isEnabled = false
                        sync.text = "Syncing…"
                        refresh()
                        thread {
                            val (code, out) = DaemonService.runFullSync(this@MainActivity)
                            runOnUiThread {
                                sync.isEnabled = true
                                sync.text = "Sync"
                                Toast.makeText(
                                    this@MainActivity,
                                    if (code == 0) out.trim().takeLast(120)
                                    // It says which part it could not fetch, and
                                    // running it again is what finishes the job.
                                    else "sync incomplete — run it again\n" + out.trim().takeLast(100),
                                    Toast.LENGTH_LONG
                                ).show()
                                refresh()
                            }
                        }
                    }
                })
                addView(Button(this@MainActivity).apply {
                    text = "Settings"; setOnClickListener { showSetup() }
                })
            })
            addView(ScrollView(this@MainActivity).apply { addView(output) })
        })

        // Idempotent: the service only spawns a daemon if it has none.
        startForegroundService(Intent(this, DaemonService::class.java))
        refresh()
    }

    /**
     * targetSdk 35 draws edge to edge, so content starts at y=0 and the first
     * rows of a form end up behind the status bar — which looked exactly like
     * a missing field. Pad by whatever the system bars and keyboard occupy.
     */
    private fun setContentViewInsetAware(root: View) {
        setContentView(root)
        root.setOnApplyWindowInsetsListener { view, insets ->
            val top: Int
            val bottom: Int
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bars = insets.getInsets(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.ime()
                )
                top = bars.top
                bottom = bars.bottom
            } else {
                @Suppress("DEPRECATION") top = insets.systemWindowInsetTop
                @Suppress("DEPRECATION") bottom = insets.systemWindowInsetBottom
            }
            view.setPadding(view.paddingLeft, top, view.paddingRight, bottom)
            insets
        }
        root.requestApplyInsets()
    }

    // ── Plumbing ─────────────────────────────────────────────────────────────

    private fun column(build: LinearLayout.() -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(32, 32, 32, 32)
        build()
    }

    private fun row(build: LinearLayout.() -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        build()
    }

    private fun heading(text: String) = TextView(this).apply {
        this.text = text
        textSize = 20f
        setPadding(0, 0, 0, 24)
    }

    private fun label(text: String) = TextView(this).apply {
        this.text = text
        setPadding(0, 16, 0, 0)
    }

    private fun field(hint: String, value: String, secret: Boolean = false) =
        EditText(this).apply {
            this.hint = hint
            setText(value)
            setSingleLine()
            layoutParams = LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT)
            if (secret) {
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            }
        }
}
