package org.feverdreamtv.tsync

import android.app.Activity
import android.app.AlertDialog
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
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import org.feverdreamtv.tsync.backup.BackupPrefs
import org.feverdreamtv.tsync.backup.BackupSchedule
import org.feverdreamtv.tsync.backup.MediaAccess
import org.feverdreamtv.tsync.backup.NetworkGate
import org.feverdreamtv.tsync.backup.UploadRecords
import org.feverdreamtv.tsync.backup.UploadState
import kotlin.concurrent.thread

/**
 * Two states, not two screens: setup when there is no config, status once there
 * is. Everything shown on the status screen is `tsync status` verbatim, so it
 * cannot drift from what the desktop reports.
 */
class MainActivity : Activity() {

    private companion object {
        const val MEDIA_PERMISSIONS = 1
    }

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
                addView(heading("Camera backup"))
                backupControls().forEach { addView(it) }
            })
        })
    }

    // ── Camera backup ────────────────────────────────────────────────────────

    /**
     * Says why nothing is moving as well as how much is left: a backup that has
     * stalled and one that has finished look identical from a count alone.
     */
    private fun backupLine(): String {
        val prefs = BackupPrefs(this)
        if (!prefs.enabled) return "camera backup: off\n\n"

        // Two different backlogs: what the daemon still owes the server, and
        // what this device could not hand over and will try again.
        val queued = runCatching { Daemon.pendingUploads(Daemon.status(this)) }.getOrDefault(0)
        val stuck = UploadRecords(this).let { records ->
            try {
                records.countInState(UploadState.FAILED)
            } finally {
                records.close()
            }
        }
        val owed = queued + stuck
        // Selected-only is not a stall: the sweep runs and covers what it can
        // see, so it is said as a limit on the backup rather than a reason it
        // is not moving.
        val holding = NetworkGate.blockedBecause(this)
            ?: if (MediaAccess.level(this) == MediaAccess.Level.DENIED) {
                "no access to photos"
            } else null
        val partial = MediaAccess.level(this) == MediaAccess.Level.SELECTED_ONLY

        return buildString {
            append("camera backup: ")
            append(if (owed == 0) "up to date" else "$owed to upload")
            holding?.let { append(" — $it") }
            if (partial) append(" (only the photos you selected)")
            prefs.lastOutcome?.let { append("\nlast sweep: $it") }
            append("\n\n")
        }
    }

    private fun backupControls(): List<View> {
        val prefs = BackupPrefs(this)

        val unmetered = checkBox("Only over wifi", prefs.unmeteredOnly) {
            prefs.unmeteredOnly = it
            if (prefs.enabled) BackupSchedule.enable(this)
        }
        val battery = checkBox("Not when the battery is low", prefs.whenBatteryOk) {
            prefs.whenBatteryOk = it
            if (prefs.enabled) BackupSchedule.enable(this)
        }

        val enabled = checkBox("Back up camera photos and videos", prefs.enabled) { on ->
            prefs.enabled = on
            if (on) askAboutExistingRoll(prefs) else BackupSchedule.disable(this)
        }

        val now = Button(this).apply {
            text = "Back up now"
            setOnClickListener {
                if (!prefs.enabled) {
                    toast("Turn camera backup on first")
                } else {
                    BackupSchedule.runNow(this@MainActivity)
                    toast("Backing up…")
                }
            }
        }

        return listOf(enabled, unmetered, battery, now)
    }

    /**
     * Asked once, when backup is switched on: a roll already on the phone is
     * what someone enabling a backup usually means, and it is also the one run
     * large enough to matter.
     */
    private fun askAboutExistingRoll(prefs: BackupPrefs) {
        AlertDialog.Builder(this)
            .setTitle("Photos already on this phone")
            .setMessage("Back up the photos and videos already here, or only ones taken from now on?")
            .setPositiveButton("Everything") { _, _ -> startBackup(prefs, backfill = true) }
            .setNegativeButton("From now on") { _, _ -> startBackup(prefs, backfill = false) }
            .setCancelable(false)
            .show()
    }

    private fun startBackup(prefs: BackupPrefs, backfill: Boolean) {
        if (!backfill) BackupSchedule.skipExistingRoll(this)
        requestPermissions(MediaAccess.requested(), MEDIA_PERMISSIONS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode != MEDIA_PERMISSIONS) return
        when (MediaAccess.level(this)) {
            MediaAccess.Level.DENIED ->
                toast("tsync cannot back up photos without access to them")
            MediaAccess.Level.SELECTED_ONLY ->
                toast("Only the photos you selected will be backed up")
            MediaAccess.Level.FULL -> Unit
        }
        if (MediaAccess.canRead(this)) BackupSchedule.enable(this)
    }

    private fun checkBox(text: String, checked: Boolean, onChange: (Boolean) -> Unit) =
        CheckBox(this).apply {
            this.text = text
            isChecked = checked
            setOnCheckedChangeListener { _, value -> onChange(value) }
        }

    private fun toast(text: String) =
        Toast.makeText(this, text, Toast.LENGTH_LONG).show()

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
            val backup = backupLine()
            runOnUiThread {
                output.text = syncing + backup + text.ifBlank {
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
