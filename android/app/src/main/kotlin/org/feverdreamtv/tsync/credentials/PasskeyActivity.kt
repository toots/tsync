package org.feverdreamtv.tsync.credentials

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.annotation.RequiresApi
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PasswordCredential
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.provider.CallingAppInfo
import androidx.credentials.provider.PendingIntentHandler
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.feverdreamtv.tsync.Boot
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.ui.MainActivity
import org.feverdreamtv.tsync.Tsync
import org.feverdreamtv.tsync.autofill.Browsers
import org.feverdreamtv.tsync.core.Code
import org.feverdreamtv.tsync.core.CoreException
import org.json.JSONObject

/**
 * passwords/android §6, §7: a pick in the system's sheet. Picking tsync's entry is the approval;
 * this activity shows only the biometric prompt, when the relying party asks for verification.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyActivity : FragmentActivity() {
    private val tsync by lazy { Tsync.get(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when {
            intent.getBooleanExtra(EXTRA_CREATE, false) -> create()
            intent.getStringExtra(EXTRA_LOGIN) != null -> login(intent.getStringExtra(EXTRA_LOGIN)!!)
            intent.getStringExtra(EXTRA_ID) != null -> assert(intent.getStringExtra(EXTRA_ID)!!)
            else -> finish()
        }
    }

    private fun origin(app: CallingAppInfo): String? = try {
        app.getOrigin(Browsers.json(this))
    } catch (e: IllegalStateException) {
        null
    }

    private fun login(id: String) {
        val request = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent) ?: return finish()
        val origin = origin(request.callingAppInfo) ?: return getFailed(getString(R.string.passkey_not_offered))
        work({ tsync.passwords.fill(origin, id) }) { filled ->
            val result = Intent()
            PendingIntentHandler.setGetCredentialResponse(result, GetCredentialResponse(PasswordCredential(filled.username, filled.password)))
            done(result)
        }
    }

    private fun assert(id: String) {
        val request = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent) ?: return finish()
        val option = request.credentialOptions.filterIsInstance<GetPublicKeyCredentialOption>().firstOrNull() ?: return finish()
        val origin = origin(request.callingAppInfo) ?: return getFailed(getString(R.string.passkey_not_offered))
        val hash = option.clientDataHash ?: return getFailed(getString(R.string.passkey_not_offered))
        val json = JSONObject(option.requestJson)
        val rpId = json.optString("rpId").ifEmpty { Webauthn.host(origin) }
        verify(Webauthn.verificationAsked(json.optString("userVerification", "")), getString(R.string.passkey_sign_in, rpId)) { verified ->
            work({ tsync.passwords.passkeyAssert(origin, rpId, id, Webauthn.base64Url(hash), verified) }) { signed ->
                val clientData = Webauthn.clientData("webauthn.get", json.optString("challenge"), origin)
                val result = Intent()
                PendingIntentHandler.setGetCredentialResponse(
                    result,
                    GetCredentialResponse(
                        PublicKeyCredential(Webauthn.assertion(signed.credentialId, clientData, signed.authenticatorData, signed.signature, signed.userHandle)),
                    ),
                )
                done(result)
            }
        }
    }

    private fun create() {
        val request = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent) ?: return finish()
        val calling = request.callingRequest as? CreatePublicKeyCredentialRequest ?: return finish()
        val origin = origin(request.callingAppInfo) ?: return createFailed(getString(R.string.passkey_not_offered))
        val hash = calling.clientDataHash ?: return createFailed(getString(R.string.passkey_not_offered))
        val json = JSONObject(calling.requestJson)
        val rp = json.optJSONObject("rp")
        val rpId = rp?.optString("id")?.ifEmpty { null } ?: Webauthn.host(origin)
        val user = json.optJSONObject("user") ?: return createFailed(getString(R.string.passkey_not_offered))
        val algorithms = json.optJSONArray("pubKeyCredParams")?.let { params -> (0 until params.length()).map { params.getJSONObject(it).optInt("alg") } }.orEmpty()
        val asked = Webauthn.verificationAsked(json.optJSONObject("authenticatorSelection")?.optString("userVerification", ""))
        verify(asked, getString(R.string.passkey_save, rpId)) { verified ->
            work({
                tsync.passwords.passkeyCreate(
                    origin, rpId, user.optString("id"), user.optString("name"), user.optString("displayName"),
                    algorithms, Webauthn.ids(json.optJSONArray("excludeCredentials")), Webauthn.base64Url(hash), verified,
                )
            }, onRefused = { e ->
                if (e.code == Code.EXISTS) {
                    val result = Intent()
                    PendingIntentHandler.setCreateCredentialException(result, CreatePublicKeyCredentialDomException(InvalidStateError(), e.message))
                    done(result)
                } else if (e.code == Code.LOCKED) {
                    // §1: a create has no entry to say so before the pick; the Vault screen opens instead.
                    startActivity(Intent(this, MainActivity::class.java).putExtra(MainActivity.EXTRA_SHOW_VAULT, true))
                    createFailed(getString(R.string.autofill_locked))
                } else createFailed(e.message.orEmpty())
            }) { made ->
                tsync.vaultChanges.value++
                val clientData = Webauthn.clientData("webauthn.create", json.optString("challenge"), origin)
                val result = Intent()
                PendingIntentHandler.setCreateCredentialResponse(
                    result,
                    CreatePublicKeyCredentialResponse(
                        Webauthn.registration(made.credentialId, clientData, made.attestationObject, made.authenticatorData, made.publicKey, made.algorithm),
                    ),
                )
                done(result)
            }
        }
    }

    /** §7: the platform's prompt when asked; a cancel cancels the request. */
    private fun verify(asked: Boolean, title: String, then: (Boolean) -> Unit) {
        if (!asked) return then(false)
        val prompt = BiometricPrompt(
            this, ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = then(true)
                override fun onAuthenticationError(code: Int, message: CharSequence) = cancelled()
            },
        )
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder().setTitle(title).setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL).build(),
        )
    }

    private fun <T> work(call: () -> T, onRefused: ((CoreException) -> Unit)? = null, then: (T) -> Unit) {
        tsync.scope.launch {
            val outcome = runCatching {
                if (tsync.boot() != Boot.Ready) throw CoreException(Code.UNREACHABLE, getString(R.string.save_login_not_ready))
                call()
            }
            withContext(Dispatchers.Main) {
                outcome.onSuccess(then).onFailure { e ->
                    val refused = e as? CoreException
                    when {
                        refused != null && onRefused != null -> onRefused(refused)
                        intent.getBooleanExtra(EXTRA_CREATE, false) -> createFailed(e.message.orEmpty())
                        else -> getFailed(e.message.orEmpty())
                    }
                }
            }
        }
    }

    private fun cancelled() {
        val result = Intent()
        if (intent.getBooleanExtra(EXTRA_CREATE, false)) {
            PendingIntentHandler.setCreateCredentialException(result, CreateCredentialCancellationException())
        } else {
            PendingIntentHandler.setGetCredentialException(result, GetCredentialCancellationException())
        }
        done(result)
    }

    private fun getFailed(reason: String) {
        val result = Intent()
        PendingIntentHandler.setGetCredentialException(result, GetCredentialUnknownException(reason))
        done(result)
    }

    private fun createFailed(reason: String) {
        val result = Intent()
        PendingIntentHandler.setCreateCredentialException(result, CreateCredentialUnknownException(reason))
        done(result)
    }

    private fun done(result: Intent) {
        setResult(RESULT_OK, result)
        finish()
    }

    companion object {
        const val EXTRA_ID = "org.feverdreamtv.tsync.credentials.ID"
        const val EXTRA_LOGIN = "org.feverdreamtv.tsync.credentials.LOGIN"
        const val EXTRA_CREATE = "org.feverdreamtv.tsync.credentials.CREATE"
    }
}
