package org.feverdreamtv.tsync.backup

import android.content.Context

/**
 * Camera backup settings.
 *
 * Kept beside the app rather than in the daemon's config.json: the daemon serves
 * a domain and has no notion of a camera roll, and these differ per device even
 * when the domain does not.
 */
class BackupPrefs(context: Context) {

    private val prefs =
        context.getSharedPreferences("camera-backup", Context.MODE_PRIVATE)

    var enabled: Boolean
        get() = prefs.getBoolean(ENABLED, false)
        set(value) = prefs.edit().putBoolean(ENABLED, value).apply()

    var unmeteredOnly: Boolean
        get() = prefs.getBoolean(UNMETERED_ONLY, true)
        set(value) = prefs.edit().putBoolean(UNMETERED_ONLY, value).apply()

    var whenBatteryOk: Boolean
        get() = prefs.getBoolean(BATTERY_OK, true)
        set(value) = prefs.edit().putBoolean(BATTERY_OK, value).apply()

    /** Why the last sweep did nothing, for a status screen that would otherwise
     *  render a stall and a finished backup identically. */
    var lastOutcome: String?
        get() = prefs.getString(LAST_OUTCOME, null)
        set(value) = prefs.edit().putString(LAST_OUTCOME, value).apply()

    /**
     * Whether the last sweep reached the end of the roll with nothing left.
     *
     * The only honest source for "up to date": an upload no longer sits in a
     * queue anyone can measure, so between sweeps nothing else distinguishes a
     * finished backup from one that has not started. Null until a sweep has run.
     */
    var settled: Boolean?
        get() = if (prefs.contains(SETTLED)) prefs.getBoolean(SETTLED, false) else null
        set(value) =
            prefs.edit().apply {
                if (value == null) remove(SETTLED) else putBoolean(SETTLED, value)
            }.apply()

    private companion object {
        const val ENABLED = "enabled"
        const val UNMETERED_ONLY = "unmeteredOnly"
        const val BATTERY_OK = "whenBatteryOk"
        const val LAST_OUTCOME = "lastOutcome"
        const val SETTLED = "settled"
    }
}
