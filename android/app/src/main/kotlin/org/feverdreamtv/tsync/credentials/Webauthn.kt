package org.feverdreamtv.tsync.credentials

import android.net.Uri
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/** WebAuthn's JSON forms (L3 §5.1.8, §5.1.9) around the owner's passkey requests (passwords §7.5). */
object Webauthn {
    fun host(origin: String): String = Uri.parse(origin).host.orEmpty()

    fun ids(descriptors: JSONArray?): List<String> =
        (0 until (descriptors?.length() ?: 0)).mapNotNull { descriptors!!.optJSONObject(it)?.optString("id")?.takeIf(String::isNotEmpty) }

    fun base64Url(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    /** Required when verification is not `discouraged` (§7); WebAuthn's default is `preferred`. */
    fun verificationAsked(value: String?): Boolean = (value ?: "preferred") != "discouraged"

    /** The browser's client data stands; this one is what a relying party would see. */
    fun clientData(type: String, challenge: String, origin: String): String =
        base64Url(JSONObject().put("type", type).put("challenge", challenge).put("origin", origin).put("crossOrigin", false).toString().toByteArray())

    fun assertion(credentialId: String, clientData: String, authenticatorData: String, signature: String, userHandle: String): String =
        JSONObject().put("id", credentialId).put("rawId", credentialId).put("type", "public-key").put("authenticatorAttachment", "platform")
            .put(
                "response",
                JSONObject().put("clientDataJSON", clientData).put("authenticatorData", authenticatorData)
                    .put("signature", signature).put("userHandle", userHandle),
            )
            .put("clientExtensionResults", JSONObject()).toString()

    fun registration(
        credentialId: String,
        clientData: String,
        attestationObject: String,
        authenticatorData: String,
        publicKey: String,
        algorithm: Int,
    ): String =
        JSONObject().put("id", credentialId).put("rawId", credentialId).put("type", "public-key").put("authenticatorAttachment", "platform")
            .put(
                "response",
                JSONObject().put("clientDataJSON", clientData).put("attestationObject", attestationObject)
                    .put("authenticatorData", authenticatorData).put("transports", JSONArray(listOf("internal", "hybrid")))
                    .put("publicKey", publicKey).put("publicKeyAlgorithm", algorithm),
            )
            .put("clientExtensionResults", JSONObject().put("credProps", JSONObject().put("rk", true))).toString()
}
