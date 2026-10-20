package org.feverdreamtv.tsync.core

import org.json.JSONObject
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * extensions/passwords/android.md. The owner's verbs are tested on the owner's side; a process per
 * call cannot hold an unlocked vault (the desktop has no keystore), so here: the locked path against
 * a real owner, and the replies' reading against the shapes the owner answers.
 */
class PasswordsTest {
    private val binary: String? = System.getenv("TSYNC_BIN")

    @Test
    fun aLockedVaultRefusesEveryAutofillRequest() {
        if (binary == null) {
            System.err.println("*** PasswordsTest skipped: TSYNC_BIN is unset ***")
            assumeTrue(false, "TSYNC_BIN is unset")
        }
        val home = Files.createTempDirectory("tsync-passwords").toFile()
        val store = File(home, "store").apply { mkdirs() }
        val backend = JSONObject().put("type", "local").put("name", "store").put("role", "main").put("path", store.path)
        val domain = JSONObject().put("name", "Passwords Suite").put("versioning", true)
            .put("frontends", listOf("android")).put("backends", listOf(backend)).put("extensions", listOf("passwords"))
        val client = Client(ProcessCore(binary!!, home, JSONObject().put("name", "passwords").put("domains", listOf(domain)).toString()))
        client.call(JSONObject().put("action", "vault_init").put("passphrase", "correct horse battery staple"))
        val passwords = Passwords(client)
        for (request in listOf<() -> Unit>(
            { passwords.list(site = "https://github.com", pull = Pull.BACKGROUND) },
            { passwords.fill("https://github.com", "0".repeat(32)) },
            { passwords.save("https://github.com", "me", "hunter2") },
        )) assertEquals(Code.LOCKED, assertFailsWith<CoreException> { request() }.code)
    }

    /** Answers each action with the reply the owner gives it. */
    private class Answering(private val replies: Map<String, String>) : Core {
        val asked = mutableListOf<JSONObject>()
        override fun request(json: String): String {
            val request = JSONObject(json).also { asked += it }
            return replies.getValue(request.getString("action"))
        }
        override fun status() = "{}"
        override fun checkConfig(domain: String, candidate: String?): String? = null
        override fun boot(domain: String): String? = null
        override fun open(ref: String): Long = error("unused")
        override fun size(handle: Long): Long = error("unused")
        override fun read(handle: Long, offset: Long, length: Int, dest: ByteArray): Int = error("unused")
        override fun close(handle: Long): Int = error("unused")
    }

    @Test
    fun aListIsReadAsLoginsAndPasskeysAndAsksForABackgroundPull() {
        val core = Answering(
            mapOf(
                "passwords_list" to """{"ok":true,"records":[
                    {"id":"a","kind":"login","title":"GitHub","username":"me","urls":["https://github.com"],"code":true,"dangling":false,"passkeys":[]},
                    {"id":"b","kind":"passkey","rpId":"github.com","userName":"me","credentialId":"Y3JlZA","userHandle":"aA","login":""}],
                    "corrupt":[],"outdated":true,"pulledAt":1700000000}""",
            ),
        )
        val records = Passwords(Client(core)).list(site = "https://github.com", pull = Pull.BACKGROUND)
        assertEquals(listOf(LoginRow("a", "GitHub", "me", listOf("https://github.com"), true)), records.logins)
        assertEquals(listOf(PasskeyRow("b", "github.com", "me")), records.passkeys)
        assertEquals(true, records.outdated)
        assertEquals("background", core.asked.single().getString("pull"))
    }

    @Test
    fun aSaveIsReadAsDoneUnchangedOrUpdate() {
        fun saved(reply: String) = Passwords(Client(Answering(mapOf("passwords_save" to reply)))).save("https://x.org", "a", "b")
        assertEquals(Saved.Done("i"), saved("""{"ok":true,"saved":true,"id":"i"}"""))
        assertEquals(Saved.Unchanged, saved("""{"ok":true,"saved":false}"""))
        assertEquals(Saved.Update("i"), saved("""{"ok":true,"saved":false,"update":"i"}"""))
    }

    @Test
    fun aFillCarriesTheCodeWhenOneIsLinked() {
        val core = Answering(mapOf("passwords_fill" to """{"ok":true,"username":"me","password":"p","code":"123456","secondsLeft":9}"""))
        assertEquals(Filled("me", "p", "123456"), Passwords(Client(core)).fill("https://github.com", "a"))
    }
}
