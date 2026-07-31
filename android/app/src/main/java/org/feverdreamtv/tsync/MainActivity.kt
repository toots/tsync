package org.feverdreamtv.tsync

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import kotlin.concurrent.thread

/**
 * Two states, not two screens: setup when there is no config, status once there
 * is. Everything shown on the status screen is `tsync stats` verbatim, so it
 * cannot drift from what the desktop reports.
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Config.exists(this)) showStatus() else showSetup()
    }

    // ── Setup ────────────────────────────────────────────────────────────────

    private fun showSetup() {
        val existing = Config.load(this)
        val domain = field("Domain name", existing?.domain ?: "media")
        val url = field("Server URL", existing?.url ?: "http://192.168.1.10:8443")
        val secret = field("Shared secret", existing?.secret ?: "", secret = true)
        val cache = field("Cache limit", existing?.maxCache ?: "2G")
        val error = TextView(this).apply { setPadding(0, 8, 0, 8) }

        val save = Button(this).apply {
            text = "Save and start"
            setOnClickListener {
                val settings = Config.Settings(
                    domain.text.toString().trim(),
                    url.text.toString().trim(),
                    secret.text.toString().trim(),
                    cache.text.toString().trim().ifBlank { "2G" }
                )
                Config.validate(settings)?.let { error.text = it; return@setOnClickListener }

                Config.save(this@MainActivity, settings)
                // The daemon is the authority on whether its own config parses;
                // anything else here would be a second implementation that drifts.
                val (code, output) = DaemonService.run(this@MainActivity, "print-config")
                if (code != 0) {
                    error.text = "tsync rejected the config:\n$output"
                    return@setOnClickListener
                }
                startForegroundService(Intent(this@MainActivity, DaemonService::class.java))
                showStatus()
            }
        }

        setContentView(ScrollView(this).apply {
            addView(column {
                addView(heading("Connect to your tsync server"))
                addView(label("Domain name"));   addView(domain)
                addView(label("Server URL"));    addView(url)
                addView(label("Shared secret")); addView(secret)
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

        fun refresh() = thread {
            val (_, text) = DaemonService.run(this, "stats")
            runOnUiThread { output.text = text.ifBlank { "no response — is the daemon running?" } }
        }

        setContentView(column {
            addView(row {
                addView(Button(this@MainActivity).apply {
                    text = "Refresh"; setOnClickListener { refresh() }
                })
                addView(Button(this@MainActivity).apply {
                    text = "Sync"
                    setOnClickListener {
                        thread {
                            val (_, out) = DaemonService.run(this@MainActivity, "sync", "--full")
                            runOnUiThread {
                                Toast.makeText(this@MainActivity, out.trim().takeLast(120), Toast.LENGTH_LONG).show()
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
