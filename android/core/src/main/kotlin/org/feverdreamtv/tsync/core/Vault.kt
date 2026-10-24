package org.feverdreamtv.tsync.core

import org.json.JSONObject

/** The vault's state (extensions/vault §8), as `vault_status` answers it. */
data class VaultStatus(
    val state: String,
    val enrolled: Boolean,
    val cached: String?,
    val keystoreError: String?,
    /** extensions README §4.1: answered from the last view, of that age. */
    val outdated: Boolean = false,
    val pulledAt: Long? = null,
    val appearance: Appearance? = null,
    /** vault §6.3: the machines that joined since this phone last acknowledged them. */
    val newMachines: List<String> = emptyList(),
    /** vault §7.2: the secret key this phone holds opens no slot any more. */
    val secretKeyReplaced: Boolean = false,
)

/** vault §8.1: the colour in force (`#rrggbb`), and the icon's PNG bytes when there is one. */
class Appearance(val color: String, val colorChosen: Boolean, val icon: ByteArray?)

data class OneTimeCode(val id: String, val issuer: String, val account: String, val code: String, val secondsLeft: Int)

data class Codes(val records: List<OneTimeCode>, val corrupt: Int, val outdated: Boolean = false, val pulledAt: Long? = null)

data class Refusal(val line: Int, val reason: String)

data class Imported(val added: Int, val already: Int, val refused: List<Refusal>)

/** android-app §10.8. The phone follows the domain: no init, delete, passphrase change or export. */
class Vault(private val client: Client) {
    private fun action(name: String) = JSONObject().put("action", name)

    /** Null when the domain uses no extension here (05 §2.1 rule 5): no Vault destination. */
    fun status(): VaultStatus? {
        val reply = try {
            client.call(action("vault_status"))
        } catch (e: CoreException) {
            if (e.code == Code.INVALID) return null
            throw e
        }
        return VaultStatus(
            state = reply.optString("vault", "absent"),
            enrolled = reply.optBoolean("enrolled", false),
            cached = text(reply, "cached"),
            keystoreError = text(reply, "keystoreError"),
            outdated = reply.optBoolean("outdated", false),
            pulledAt = if (reply.has("pulledAt")) reply.optLong("pulledAt") else null,
            appearance = reply.optJSONObject("appearance")?.let {
                Appearance(
                    color = it.optString("color"),
                    colorChosen = it.optBoolean("colorChosen"),
                    icon = text(it, "icon")?.let { b64 -> java.util.Base64.getDecoder().decode(b64) },
                )
            },
            newMachines = reply.optJSONArray("newMachines")?.let { names ->
                (0 until names.length()).mapNotNull { names.opt(it) as? String }
            } ?: emptyList(),
            secretKeyReplaced = reply.optBoolean("secretKeyReplaced", false),
        )
    }

    /** vault §6.3: listing the machines acknowledges them, so the phone stops announcing them. */
    fun acknowledgeMachines() {
        client.call(action("vault_machines"))
    }

    fun unlock(passphrase: String, secretKey: String?) {
        val request = action("vault_unlock").put("passphrase", passphrase)
        secretKey?.takeIf { it.isNotBlank() }?.let { request.put("secretKey", it) }
        client.call(request)
    }

    fun lock(forget: Boolean) {
        client.call(action("vault_lock").put("forget", forget))
    }

    /** vault §6.2: the screen went off; the owner locks only under a policy that asks for it. */
    fun screenLocked() {
        client.call(action("vault_lock").put("reason", "screen"))
    }

    fun codes(filter: String? = null): Codes {
        val request = action("totp_list")
        filter?.takeIf { it.isNotBlank() }?.let { request.put("filter", it) }
        val reply = client.call(request)
        val records = objects(reply.optJSONArray("records")).map {
            OneTimeCode(it.getString("id"), it.optString("issuer"), it.optString("account"), it.optString("code"), it.optInt("secondsLeft"))
        }
        return Codes(
            records,
            reply.optJSONArray("corrupt")?.length() ?: 0,
            outdated = reply.optBoolean("outdated", false),
            pulledAt = if (reply.has("pulledAt")) reply.optLong("pulledAt") else null,
        )
    }

    /** A pasted `otpauth://` URI goes as one; anything else is a bare secret (totp §5.3). */
    fun add(secret: String, issuer: String = "", account: String = ""): String {
        val trimmed = secret.trim()
        val request = action("totp_add")
        if (trimmed.startsWith("otpauth://")) request.put("uri", trimmed)
        else request.put("secret", trimmed).put("issuer", issuer.trim()).put("account", account.trim())
        return client.call(request).getString("id")
    }

    fun rename(id: String, issuer: String, account: String) {
        client.call(action("totp_rename").put("id", id).put("issuer", issuer).put("account", account))
    }

    fun remove(id: String) {
        client.call(action("totp_remove").put("id", id))
    }

    fun import(text: String): Imported {
        val reply = client.call(action("totp_import").put("text", text))
        return Imported(
            added = reply.optInt("added"),
            already = reply.optInt("already"),
            refused = objects(reply.optJSONArray("refused")).map { Refusal(it.optInt("line"), it.optString("reason")) },
        )
    }
}
