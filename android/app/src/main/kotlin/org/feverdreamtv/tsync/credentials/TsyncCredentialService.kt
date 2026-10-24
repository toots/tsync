package org.feverdreamtv.tsync.credentials

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.provider.AuthenticationAction
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPasswordOption
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CallingAppInfo
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.PasswordCredentialEntry
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import kotlinx.coroutines.launch
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.autofill.Browsers
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.feverdreamtv.tsync.core.Pull
import org.feverdreamtv.tsync.ui.MainActivity
import org.json.JSONObject

/** passwords/android §6: Credential Manager, for the browsers of the list (§2). Nothing is signed or read before a pick. */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class TsyncCredentialService : CredentialProviderService() {
    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        val tsync = Tsync.get(this)
        val job = tsync.scope.launch {
            try {
                callback.onResult(entries(tsync, request))
            } catch (e: CoreException) {
                Log.w(Tsync.TAG, "credentials: the owner refused: ${e.code.wire}: ${e.message}")
                if (e.code == Code.LOCKED) callback.onResult(locked()) else callback.onResult(BeginGetCredentialResponse())
            } catch (e: Throwable) {
                Log.w(Tsync.TAG, "credentials: no answer", e)
                callback.onError(GetCredentialUnknownException(e.message))
            }
        }
        cancellationSignal.setOnCancelListener { job.cancel() }
    }

    /** §6.3: the caller's web origin, only for a browser of the list. */
    private fun origin(app: CallingAppInfo?): String? = try {
        app?.getOrigin(Browsers.json(this))
    } catch (e: Exception) {
        Log.w(Tsync.TAG, "credentials: the browser list was refused: ${e.message}")
        null
    }

    private fun entries(tsync: Tsync, request: BeginGetCredentialRequest): BeginGetCredentialResponse {
        val app = request.callingAppInfo
        val origin = origin(app)
        // §6.1: the platform may give no origin before the pick; a listed browser is then listed
        // for the request's RP ID, and the pick checks the browser's origin before anything is signed.
        val browser = origin != null || (app != null && Browsers.isBrowser(this, app.packageName))
        if (!browser) {
            Log.w(Tsync.TAG, "credentials: ${app?.packageName} is not a listed browser")
            return BeginGetCredentialResponse()
        }
        if (tsync.boot() != Boot.Ready) return BeginGetCredentialResponse()
        val mark = org.feverdreamtv.tsync.autofill.TsyncIcon.of(this)
        val entries = mutableListOf<CredentialEntry>()
        for (option in request.beginGetCredentialOptions) {
            when (option) {
                is BeginGetPublicKeyCredentialOption -> {
                    val json = JSONObject(option.requestJson)
                    val rpId = json.optString("rpId").ifEmpty { origin?.let(Webauthn::host).orEmpty() }
                    if (rpId.isEmpty()) continue
                    val allow = Webauthn.ids(json.optJSONArray("allowCredentials"))
                    val asked = origin ?: "https://$rpId"
                    val matched = tsync.passwords.passkeyMatch(asked, rpId, allow, pull = Pull.BACKGROUND)
                    Log.i(Tsync.TAG, "credentials: $rpId, origin ${if (origin == null) "after the pick" else origin}, ${allow.size} allowed, ${matched.size} matched")
                    for (passkey in matched) {
                        val pick = pending(Intent(this, PasskeyActivity::class.java).putExtra(PasskeyActivity.EXTRA_ID, passkey.id), passkey.id)
                        entries += PublicKeyCredentialEntry.Builder(this, passkey.userName, pick, option)
                            .setDisplayName(passkey.userDisplayName.ifEmpty { null })
                            .apply { mark?.let { setIcon(it) } }.build()
                    }
                }
                is BeginGetPasswordOption -> {
                    // A login is offered for a known origin only: its password is what the pick hands over.
                    if (origin == null) continue
                    for (login in tsync.passwords.list(site = origin, pull = Pull.BACKGROUND).logins) {
                        val pick = pending(Intent(this, PasskeyActivity::class.java).putExtra(PasskeyActivity.EXTRA_LOGIN, login.id), login.id)
                        entries += PasswordCredentialEntry.Builder(this, login.username, pick, option)
                            .setDisplayName(login.title)
                            .apply { mark?.let { setIcon(it) } }.build()
                    }
                }
            }
        }
        return BeginGetCredentialResponse.Builder().setCredentialEntries(entries).build()
    }

    /** §1: the vault is unlocked in the app, never here. */
    private fun locked(): BeginGetCredentialResponse {
        val open = Intent(this, MainActivity::class.java).putExtra(MainActivity.EXTRA_SHOW_VAULT, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val action = AuthenticationAction(getString(R.string.autofill_locked), PendingIntent.getActivity(this, 1, open, PendingIntent.FLAG_IMMUTABLE))
        return BeginGetCredentialResponse.Builder().setAuthenticationActions(listOf(action)).build()
    }

    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        // §6.2: one entry; the creation itself waits for the pick.
        val app = request.callingAppInfo
        val browser = origin(app) != null || (app != null && Browsers.isBrowser(this, app.packageName))
        if (request !is BeginCreatePublicKeyCredentialRequest || !browser) {
            return callback.onError(CreateCredentialUnknownException(getString(R.string.passkey_not_offered)))
        }
        val tsync = Tsync.get(this)
        val pick = pending(Intent(this, PasskeyActivity::class.java).putExtra(PasskeyActivity.EXTRA_CREATE, true), "create")
        callback.onResult(BeginCreateCredentialResponse.Builder().addCreateEntry(CreateEntry.Builder(tsync.domain.ifEmpty { "tsync" }, pick).build()).build())
    }

    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<Void?, ClearCredentialException>,
    ) = callback.onResult(null)

    private fun pending(intent: Intent, key: String): PendingIntent =
        PendingIntent.getActivity(this, key.hashCode(), intent, PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
}
