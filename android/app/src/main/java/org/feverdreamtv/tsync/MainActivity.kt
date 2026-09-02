package org.feverdreamtv.tsync

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowInsets
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.text.format.Formatter
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.ArrayAdapter
import android.widget.AutoCompleteTextView
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import org.feverdreamtv.tsync.backup.BackupPrefs
import org.feverdreamtv.tsync.backup.BackupSchedule
import org.feverdreamtv.tsync.backup.MediaAccess
import org.feverdreamtv.tsync.backup.NetworkGate
import org.feverdreamtv.tsync.backup.UploadRecords
import org.feverdreamtv.tsync.backup.UploadState
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Setup until there is a config, then the domain's files, with settings and
 * status a button away. Everything shown on the status screen is `tsync status`
 * verbatim, so it cannot drift from what the desktop reports.
 */
class MainActivity : Activity() {

    private companion object {
        const val MEDIA_PERMISSIONS = 1

        /** Rows fetched per listing call; the next page loads as the list
         *  nears its end. */
        const val PAGE = 200
    }

    /** What back does on the screen showing; false hands it to the platform. */
    private var onBack: () -> Boolean = { false }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Config.exists(this)) {
            TsyncProvider.notifyRootsChanged(this)
            showBrowser()
        } else showSetup()
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (!onBack()) super.onBackPressed()
    }

    // ── Browser ──────────────────────────────────────────────────────────────

    /** The folders opened to get here, root excluded: reference and name. */
    private val trail = ArrayDeque<Pair<String, String>>()

    private fun showBrowser() {
        val here = trail.lastOrNull()?.first ?: Cli.ROOT
        val rows = ArrayList<JSONObject>()
        val adapter = object : ArrayAdapter<JSONObject>(
            this, android.R.layout.simple_list_item_2, android.R.id.text1, rows
        ) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val view = super.getView(position, convertView, parent)
                val entry = getItem(position)!!
                val isDir = entry.getString("kind") == "dir"
                val name = entry.getString("name")
                view.findViewById<TextView>(android.R.id.text1).text =
                    if (isDir) "$name/" else name
                view.findViewById<TextView>(android.R.id.text2).text =
                    if (isDir) "folder"
                    else Formatter.formatShortFileSize(context, entry.optLong("size"))
                return view
            }
        }
        val list = ListView(this).apply { this.adapter = adapter }
        val notice = TextView(this).apply { setPadding(0, 8, 0, 8) }

        // "" asks for the first page; null means the folder has been read.
        var next: String? = ""
        var loading = false
        fun loadMore() {
            val after = next ?: return
            if (loading) return
            loading = true
            notice.text = "reading…"
            thread {
                val page = runCatching { Tsync.json(this, Cli.list(here, after, PAGE)) }
                runOnUiThread {
                    loading = false
                    page.onFailure {
                        next = null
                        notice.text = "Cannot read this folder: ${it.message}"
                    }
                    page.onSuccess { reply ->
                        val items = reply.getJSONArray("items")
                        for (i in 0 until items.length()) rows += items.getJSONObject(i)
                        adapter.notifyDataSetChanged()
                        next = reply.optString("next", "").ifEmpty { null }
                        notice.text = if (rows.isEmpty()) "Empty folder" else ""
                    }
                }
            }
        }

        list.setOnScrollListener(object : AbsListView.OnScrollListener {
            override fun onScrollStateChanged(view: AbsListView, state: Int) {}
            override fun onScroll(view: AbsListView, first: Int, visible: Int, total: Int) {
                if (first + visible >= total - 10) loadMore()
            }
        })
        list.setOnItemClickListener { _, _, position, _ ->
            val entry = rows[position]
            if (entry.getString("kind") == "dir") {
                trail.addLast(entry.getString("ref") to entry.getString("name"))
                showBrowser()
            } else offerLink(entry)
        }
        list.setOnItemLongClickListener { _, _, position, _ ->
            offerLink(rows[position])
            true
        }

        onBack = {
            if (trail.isEmpty()) false
            else {
                trail.removeLast()
                showBrowser()
                true
            }
        }
        setContentViewInsetAware(column {
            addView(row {
                addView(Button(this@MainActivity).apply {
                    text = "Settings"; setOnClickListener { showSetup() }
                })
                addView(Button(this@MainActivity).apply {
                    text = "Status"; setOnClickListener { showStatus() }
                })
            })
            addView(heading(trail.joinToString("/") { it.second }.ifEmpty { "tsync" }))
            addView(notice)
            addView(list, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        })
        loadMore()
    }

    private fun offerLink(entry: JSONObject) {
        val name = entry.getString("name")
        AlertDialog.Builder(this)
            .setTitle(name)
            .setItems(arrayOf("Share link")) { _, _ -> shareLink(entry.getString("ref"), name) }
            .show()
    }

    /** The link is the server's to mint, so it is asked for and shown once it
     *  answers, with the two things a person does with one. */
    private fun shareLink(ref: String, name: String) {
        toast("Publishing a link to $name…")
        thread {
            val link = runCatching { Tsync.json(this, Cli.share(ref)).getString("url") }
            runOnUiThread {
                link.onFailure { toast("Cannot share $name: ${it.message}") }
                link.onSuccess { url ->
                    AlertDialog.Builder(this)
                        .setTitle("Link to $name")
                        .setMessage(url)
                        .setPositiveButton("Copy") { _, _ ->
                            getSystemService(ClipboardManager::class.java)
                                .setPrimaryClip(ClipData.newPlainText(name, url))
                            toast("Link copied")
                        }
                        .setNeutralButton("Send") { _, _ ->
                            startActivity(Intent.createChooser(
                                Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_TEXT, url)
                                }, null))
                        }
                        .setNegativeButton("Close", null)
                        .show()
                }
            }
        }
    }

    // ── Setup ────────────────────────────────────────────────────────────────

    private fun showSetup() {
        val existing = Config.load(this)
        onBack = {
            if (existing == null) false
            else {
                showBrowser()
                true
            }
        }
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
                // The binary is the authority on whether its own config parses;
                // anything else here would be a second implementation that drifts.
                val (code, output) = Tsync.plain(this@MainActivity, "config")
                if (code != 0) {
                    error.text = "tsync rejected the config:\n$output"
                    return@setOnClickListener
                }
                // The root's id and title come from the config, so the picker
                // is holding a stale answer until it re-queries.
                TsyncProvider.notifyRootsChanged(this@MainActivity)
                showBrowser()
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

        val records = UploadRecords(this)
        val failed: Int
        val reason: String?
        try {
            failed = records.countInState(UploadState.FAILED)
            reason = if (failed > 0) records.lastError() else null
        } finally {
            records.close()
        }

        // Selected-only is not a stall: the sweep runs and covers what it can
        // see, so it is said as a limit on the backup rather than a reason it
        // is not moving.
        val holding = NetworkGate.blockedBecause(this)
            ?: if (MediaAccess.level(this) == MediaAccess.Level.DENIED) {
                "no access to photos"
            } else null
        val partial = MediaAccess.level(this) == MediaAccess.Level.SELECTED_ONLY

        // "up to date" is a claim about the whole roll, and only a sweep that
        // reached the end of it can make one: an upload is no longer held in a
        // queue anyone can count, so a quiet moment says nothing by itself.
        val state = when {
            failed > 0 -> "$failed failed"
            prefs.settled == null -> "not started yet"
            prefs.settled == false -> "more to upload"
            else -> "up to date"
        }

        return buildString {
            append("camera backup: ")
            append(state)
            reason?.let { append(" — ${it.take(80)}") }
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
        onBack = {
            showBrowser()
            true
        }
        val output = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 10f
        }

        fun refresh() = thread {
            runOnUiThread { output.text = "reading…" }
            val (code, text) = Tsync.plain(this, Cli.status())
            val backup = backupLine()
            runOnUiThread {
                output.text = backup + text.ifBlank {
                    "tsync reported nothing (exit $code) — check `adb logcat -s tsync`"
                }
            }
        }

        setContentViewInsetAware(column {
            addView(row {
                addView(Button(this@MainActivity).apply {
                    text = "Files"; setOnClickListener { showBrowser() }
                })
                addView(Button(this@MainActivity).apply {
                    text = "Refresh"; setOnClickListener { refresh() }
                })
            })
            addView(ScrollView(this@MainActivity).apply { addView(output) })
        })

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
