package org.feverdreamtv.tsync.autofill

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import androidx.core.content.IntentCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Pull

/**
 * passwords/android §3, §4: the pick. Shows nothing; asks the owner for the login of this site
 * and hands the platform the dataset with its values.
 */
class FillActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val site = intent.getStringExtra(EXTRA_SITE) ?: return done(null)
        val tsync = Tsync.get(this)
        if (intent.getBooleanExtra(EXTRA_SUGGEST, false)) return suggest(tsync, site)
        val id = intent.getStringExtra(EXTRA_ID) ?: return done(null)
        tsync.scope.launch {
            val dataset = try {
                if (tsync.boot() != Boot.Ready) null
                else dataset(tsync.passwords.fill(site, id, pull = Pull.BACKGROUND))
            } catch (e: Exception) {
                null
            }
            withContext(Dispatchers.Main) { done(dataset) }
        }
    }

    /** passwords §5.1: the login is saved now; the submit only sets its username. */
    @Suppress("DEPRECATION")
    private fun suggest(tsync: Tsync, site: String) {
        tsync.scope.launch {
            val dataset = try {
                if (tsync.boot() != Boot.Ready) null
                else {
                    val suggestion = tsync.passwords.suggest(site, intent.getStringExtra(EXTRA_TYPED_USERNAME).orEmpty())
                    Saving.suggested(site, suggestion.id, suggestion.password)
                    tsync.vaultChanges.value++
                    val builder = Dataset.Builder()
                    ids(EXTRA_PASSWORD).forEach { builder.setValue(it, AutofillValue.forText(suggestion.password)) }
                    if (ids(EXTRA_PASSWORD).isEmpty()) null else builder.build()
                }
            } catch (e: Exception) {
                null
            }
            withContext(Dispatchers.Main) { done(dataset) }
        }
    }

    @Suppress("DEPRECATION")
    private fun dataset(filled: org.feverdreamtv.tsync.core.Filled): Dataset? {
        val builder = Dataset.Builder()
        var any = false
        fun put(key: String, text: String?) {
            if (text == null) return
            for (field in ids(key)) {
                builder.setValue(field, AutofillValue.forText(text))
                any = true
            }
        }
        put(EXTRA_USERNAME, filled.username.takeIf { it.isNotEmpty() })
        put(EXTRA_PASSWORD, filled.password)
        put(EXTRA_CODE, filled.code)
        return if (any) builder.build() else null
    }

    private fun ids(key: String): List<AutofillId> =
        IntentCompat.getParcelableArrayListExtra(intent, key, AutofillId::class.java).orEmpty()

    private fun done(dataset: Dataset?) {
        if (dataset == null) setResult(RESULT_CANCELED)
        else setResult(RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset))
        finish()
    }

    companion object {
        const val EXTRA_SITE = "org.feverdreamtv.tsync.autofill.SITE"
        const val EXTRA_ID = "org.feverdreamtv.tsync.autofill.ID"
        const val EXTRA_USERNAME = "org.feverdreamtv.tsync.autofill.USERNAME"
        const val EXTRA_PASSWORD = "org.feverdreamtv.tsync.autofill.PASSWORD"
        const val EXTRA_CODE = "org.feverdreamtv.tsync.autofill.CODE"
        const val EXTRA_SUGGEST = "org.feverdreamtv.tsync.autofill.SUGGEST"
        const val EXTRA_TYPED_USERNAME = "org.feverdreamtv.tsync.autofill.TYPED_USERNAME"
    }
}
