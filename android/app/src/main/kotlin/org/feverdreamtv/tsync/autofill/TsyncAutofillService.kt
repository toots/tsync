package org.feverdreamtv.tsync.autofill

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import android.util.Log
import android.widget.RemoteViews
import kotlinx.coroutines.launch
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Served
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.LoginRow
import org.feverdreamtv.tsync.core.Pull
import org.feverdreamtv.tsync.ui.MainActivity

/** passwords/android §3–§5. Requests arrive on the main thread; the owner is asked off it. */
class TsyncAutofillService : AutofillService() {
    override fun onFillRequest(request: FillRequest, cancellation: CancellationSignal, callback: FillCallback) {
        val form = request.fillContexts.lastOrNull()?.structure?.let { Form.of(this, it) } ?: return callback.onSuccess(null)
        val tsync = Tsync.get(this)
        val job = tsync.scope.launch {
            val response = try {
                respond(tsync, form)
            } catch (e: Throwable) {
                Log.w(Tsync.TAG, "autofill: no answer", e)
                null
            }
            if (!cancellation.isCanceled) callback.onSuccess(response)
        }
        cancellation.setOnCancelListener { job.cancel() }
    }

    private fun respond(tsync: Tsync, form: Form): FillResponse? {
        val domains = tsync.using("passwords")
        if (domains.isEmpty()) return null
        val certs = Browsers.certificatesOf(this, form.site)
        val logins = mutableListOf<Pair<Served, LoginRow>>()
        val locked = mutableListOf<Served>()
        // ponytail: domains asked in turn, so a slow one delays the answer; ask them concurrently under the platform's deadline if that shows.
        for (domain in domains) {
            try {
                // §3: what the phone holds, at once; the pull goes on for the next request.
                domain.passwords.list(site = form.site, pull = Pull.BACKGROUND, certs = certs).logins.forEach { logins += domain to it }
            } catch (e: CoreException) {
                if (e.code == Code.LOCKED) locked += domain
            }
        }
        val named = domains.size > 1
        val mark = TsyncIcon.of(this)
        // §4: a form asking only for a code is offered the logins that link one.
        val offered = if (form.username.isEmpty() && form.password.isEmpty()) logins.filter { it.second.hasCode } else logins
        val response = FillResponse.Builder()
        offered.forEach { (domain, login) -> response.addDataset(dataset(form, domain, login, mark, named)) }
        locked.forEach { response.addDataset(locked(form, it, named)) }
        // passwords §4.3: an app may use a login no rule matched, linked once by hand.
        if (form.site.startsWith("android://")) response.addDataset(others(form))
        // passwords §5.1: a new-password field is also offered a generated password.
        if (form.newPassword) response.addDataset(suggestion(form, mark))
        val save = form.password.isNotEmpty()
        if (save) {
            val type = SaveInfo.SAVE_DATA_TYPE_PASSWORD or (if (form.username.isNotEmpty()) SaveInfo.SAVE_DATA_TYPE_USERNAME else 0)
            response.setSaveInfo(
                SaveInfo.Builder(type, form.password.toTypedArray()).apply {
                    if (form.username.isNotEmpty()) setOptionalIds(form.username.toTypedArray())
                }.build(),
            )
        }
        return if (offered.isEmpty() && locked.isEmpty() && !save && !form.newPassword && !form.site.startsWith("android://")) null
        else response.build()
    }

    /** §3: no value until the pick, which [FillActivity] answers. */
    @Suppress("DEPRECATION")
    private fun dataset(form: Form, domain: Served, login: LoginRow, mark: android.graphics.drawable.Icon?, named: Boolean): Dataset {
        val presentation = row(this, login.title, if (named) "${login.username} · ${domain.name}" else login.username, mark)
        val pick = Intent(this, FillActivity::class.java)
            .putExtra(FillActivity.EXTRA_SITE, form.site)
            .putExtra(FillActivity.EXTRA_DOMAIN, domain.name)
            .putExtra(FillActivity.EXTRA_ID, login.id)
            .putParcelableArrayListExtra(FillActivity.EXTRA_USERNAME, ArrayList(form.username))
            .putParcelableArrayListExtra(FillActivity.EXTRA_PASSWORD, ArrayList(form.password))
            .putParcelableArrayListExtra(FillActivity.EXTRA_CODE, ArrayList(form.code))
        val sender = PendingIntent.getActivity(
            this, domain.documentId(login.id).hashCode(), pick,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
        ).intentSender
        val builder = Dataset.Builder(presentation)
        form.ids.forEach { builder.setValue(it, null) }
        return builder.setAuthentication(sender).build()
    }

    /** §3: *Other logins…*, the app's search over every login. */
    @Suppress("DEPRECATION")
    private fun others(form: Form): Dataset {
        val pick = Intent(this, LinkActivity::class.java)
            .putExtra(LinkActivity.EXTRA_SITE, form.site)
            .putParcelableArrayListExtra(FillActivity.EXTRA_USERNAME, ArrayList(form.username))
            .putParcelableArrayListExtra(FillActivity.EXTRA_PASSWORD, ArrayList(form.password))
        val sender = PendingIntent.getActivity(
            this, "link:${form.site}".hashCode(), pick,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
        ).intentSender
        val builder = Dataset.Builder(row(this, getString(R.string.autofill_other_logins), getString(R.string.autofill_other_logins_detail)))
        form.ids.forEach { builder.setValue(it, null) }
        return builder.setAuthentication(sender).build()
    }

    /** §5.1: gated like a login; [FillActivity] asks for the password at the pick. */
    @Suppress("DEPRECATION")
    private fun suggestion(form: Form, mark: android.graphics.drawable.Icon?): Dataset {
        val presentation = row(this, getString(R.string.autofill_suggest), getString(R.string.autofill_suggest_detail), mark)
        val pick = Intent(this, FillActivity::class.java)
            .putExtra(FillActivity.EXTRA_SITE, form.site)
            .putExtra(FillActivity.EXTRA_SUGGEST, true)
            .putExtra(FillActivity.EXTRA_TYPED_USERNAME, form.typedUsername.orEmpty())
            .putParcelableArrayListExtra(FillActivity.EXTRA_PASSWORD, ArrayList(form.newPasswords))
        val sender = PendingIntent.getActivity(
            this, "suggest:${form.site}".hashCode(), pick,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
        ).intentSender
        val builder = Dataset.Builder(presentation)
        form.newPasswords.forEach { builder.setValue(it, null) }
        return builder.setAuthentication(sender).build()
    }

    /** §1: each locked vault is one entry that opens the Vault screen, where the user unlocks. */
    @Suppress("DEPRECATION")
    private fun locked(form: Form, domain: Served, named: Boolean): Dataset {
        val open = Intent(this, MainActivity::class.java).putExtra(MainActivity.EXTRA_SHOW_VAULT, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val sender = PendingIntent.getActivity(this, domain.name.hashCode(), open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT).intentSender
        val title = if (named) getString(R.string.autofill_locked_in, domain.name) else getString(R.string.autofill_locked)
        val builder = Dataset.Builder(row(this, title, getString(R.string.autofill_locked_detail)))
        form.ids.forEach { builder.setValue(it, null) }
        return builder.setAuthentication(sender).build()
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        val form = request.fillContexts.lastOrNull()?.structure?.let { Form.of(this, it) }
        val password = form?.typedPassword
        if (form == null || password == null) return callback.onSuccess()
        val tsync = Tsync.get(this)
        // §5: the platform's prompt was the approval; the outcome is a notification.
        callback.onSuccess()
        tsync.scope.launch { Saving.save(tsync, form.site, form.typedUsername.orEmpty(), password, update = null) }
    }

    companion object {
        fun row(context: Context, title: String, detail: String, mark: android.graphics.drawable.Icon? = null): RemoteViews =
            RemoteViews(context.packageName, R.layout.autofill_row).apply {
                setTextViewText(R.id.autofill_title, title)
                setTextViewText(R.id.autofill_detail, detail)
                if (mark != null) {
                    setImageViewIcon(R.id.autofill_mark, mark)
                    setViewVisibility(R.id.autofill_mark, android.view.View.VISIBLE)
                }
            }
    }
}
