package org.feverdreamtv.tsync.core

import org.json.JSONArray
import org.json.JSONObject

/** A login as `passwords_list` answers it: no password (passwords §10). */
data class LoginRow(val id: String, val title: String, val username: String, val urls: List<String>, val hasCode: Boolean)

data class PasskeyRow(val id: String, val rpId: String, val userName: String)

/** passwords §2.1: a note, listed by title. */
data class NoteRow(val id: String, val title: String)

data class PasswordRecords(
    val logins: List<LoginRow>,
    val passkeys: List<PasskeyRow>,
    val corrupt: Int,
    val notes: List<NoteRow> = emptyList(),
    val outdated: Boolean = false,
    val pulledAt: Long? = null,
)

/** What a fill hands the form: passwords §8 `passwords_fill`. */
data class Filled(val username: String, val password: String, val code: String?)

/** passwords §5.1: the generated password, and the login saved with it. */
data class Suggestion(val id: String, val password: String)

/** passwords §8 `passwords_save`: added or updated, nothing, or the record to update. */
sealed interface Saved {
    data class Done(val id: String?) : Saved
    data object Unchanged : Saved
    data class Update(val id: String) : Saved
}

/** A passkey the owner answers for a request (passwords §7.5). */
data class PasskeyMatch(val id: String, val credentialId: String, val userName: String, val userDisplayName: String)

data class Assertion(val credentialId: String, val authenticatorData: String, val signature: String, val userHandle: String)

data class Registration(val credentialId: String, val attestationObject: String, val authenticatorData: String, val publicKey: String, val algorithm: Int)

/** The passwords extension on the phone (extensions/passwords/android.md). Binary members are base64url. */
class Passwords(private val client: Client) {
    private fun action(name: String) = JSONObject().put("action", "passwords_$name")

    private fun JSONObject.pull(pull: Pull) = apply { pull.wire?.let { put("pull", it) } }

    fun list(site: String? = null, filter: String? = null, pull: Pull = Pull.DEFAULT): PasswordRecords {
        val request = action("list").pull(pull)
        site?.let { request.put("site", it) }
        filter?.takeIf { it.isNotBlank() }?.let { request.put("filter", it) }
        val reply = client.call(request)
        val rows = objects(reply.optJSONArray("records"))
        return PasswordRecords(
            logins = rows.filter { it.optString("kind") == "login" }.map {
                LoginRow(it.getString("id"), it.optString("title"), it.optString("username"), strings(it.optJSONArray("urls")), it.optBoolean("code"))
            },
            notes = rows.filter { it.optString("kind") == "note" }.map { NoteRow(it.getString("id"), it.optString("title")) },
            passkeys = rows.filter { it.optString("kind") == "passkey" }.map {
                PasskeyRow(it.getString("id"), it.optString("rpId"), it.optString("userName"))
            },
            corrupt = reply.optJSONArray("corrupt")?.length() ?: 0,
            outdated = reply.optBoolean("outdated", false),
            pulledAt = if (reply.has("pulledAt")) reply.optLong("pulledAt") else null,
        )
    }

    /** android §3: refused `invalid` when the login does not match [site]. */
    fun fill(site: String, id: String, pull: Pull = Pull.DEFAULT): Filled {
        val reply = client.call(action("fill").pull(pull).put("site", site).put("id", id))
        return Filled(reply.optString("username"), reply.optString("password"), text(reply, "code"))
    }

    /** The one reply with a password, for the Passwords tab's copy (android §8). */
    fun get(id: String): JSONObject = client.call(action("get").put("id", id))

    /** passwords §5.1: the login is saved at the pick. */
    fun suggest(site: String, username: String): Suggestion {
        val reply = client.call(action("suggest").put("site", site).put("username", username))
        return Suggestion(reply.getString("id"), reply.getString("password"))
    }

    /** passwords §5.1: the submit after a suggestion sets the saved login's username. */
    fun saveSuggested(site: String, username: String, id: String) {
        client.call(action("save").put("site", site).put("username", username).put("suggested", id))
    }

    fun save(site: String, username: String, password: String, update: String? = null): Saved {
        val request = action("save").put("site", site).put("username", username).put("password", password)
        update?.let { request.put("update", it) }
        val reply = client.call(request)
        text(reply, "update")?.let { return Saved.Update(it) }
        return if (reply.optBoolean("saved")) Saved.Done(text(reply, "id")) else Saved.Unchanged
    }

    fun remove(id: String) {
        client.call(action("remove").put("id", id))
    }

    fun passkeyMatch(origin: String, rpId: String, allow: List<String>, pull: Pull = Pull.DEFAULT): List<PasskeyMatch> {
        val request = action("passkey_match").pull(pull).put("origin", origin).put("rpId", rpId)
        if (allow.isNotEmpty()) request.put("allow", JSONArray(allow))
        return objects(client.call(request).optJSONArray("passkeys")).map {
            PasskeyMatch(it.getString("id"), it.optString("credentialId"), it.optString("userName"), it.optString("userDisplayName"))
        }
    }

    fun passkeyAssert(origin: String, rpId: String, id: String, clientDataHash: String, verified: Boolean): Assertion {
        val request = action("passkey_assert").put("origin", origin).put("rpId", rpId).put("id", id).put("clientDataHash", clientDataHash)
        if (verified) request.put("verified", true)
        val reply = client.call(request)
        return Assertion(reply.getString("credentialId"), reply.getString("authenticatorData"), reply.getString("signature"), reply.getString("userHandle"))
    }

    fun passkeyCreate(
        origin: String,
        rpId: String,
        userHandle: String,
        userName: String,
        userDisplayName: String,
        algorithms: List<Int>,
        exclude: List<String>,
        clientDataHash: String,
        verified: Boolean,
    ): Registration {
        val request = action("passkey_create").put("origin", origin).put("rpId", rpId).put("userHandle", userHandle)
            .put("userName", userName).put("userDisplayName", userDisplayName).put("algorithms", JSONArray(algorithms))
            .put("clientDataHash", clientDataHash)
        if (exclude.isNotEmpty()) request.put("exclude", JSONArray(exclude))
        if (verified) request.put("verified", true)
        val reply = client.call(request)
        return Registration(
            reply.getString("credentialId"), reply.getString("attestationObject"), reply.getString("authenticatorData"),
            reply.getString("publicKey"), reply.optInt("algorithm", -7),
        )
    }

    private fun strings(rows: JSONArray?): List<String> = (0 until (rows?.length() ?: 0)).map { rows!!.getString(it) }
}
