package org.feverdreamtv.tsync.core

import org.json.JSONObject
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** android-app §10.8 against a real owner: the phone follows the domain's extensions. */
class VaultTest {
    private val binary: String? = System.getenv("TSYNC_BIN")

    private fun vault(extensions: List<String>?): Pair<Vault, Client> {
        if (binary == null) {
            System.err.println("*** VaultTest skipped: TSYNC_BIN is unset ***")
            assumeTrue(false, "TSYNC_BIN is unset")
        }
        val home = Files.createTempDirectory("tsync-vault").toFile()
        val store = File(home, "store").apply { mkdirs() }
        val backend = JSONObject().put("type", "local").put("name", "store").put("role", "main").put("path", store.path)
        val domain = JSONObject().put("name", "Vault Suite").put("versioning", true)
            .put("frontends", listOf("android")).put("backends", listOf(backend))
        extensions?.let { domain.put("extensions", it) }
        val config = JSONObject().put("name", "vault").put("domains", listOf(domain)).toString()
        val client = Client(ProcessCore(binary!!, home, config))
        return Vault(client) to client
    }

    @Test
    fun aDomainUsingNoExtensionHasNoVaultDestination() {
        assertNull(vault(listOf()).first.status())
    }

    @Test
    fun aPlainStoreStatesNothingSoAnUnconfiguredDomainUsesNone() {
        assertNull(vault(null).first.status())
    }

    @Test
    fun aVaultMadeElsewhereIsLockedUntilUnlocked() {
        val (vault, client) = vault(listOf("totp"))
        assertEquals("absent", vault.status()!!.state)
        val secretKey = client.call(JSONObject().put("action", "vault_init").put("passphrase", "correct horse battery staple"))
            .getString("secretKey")
        assertEquals("locked", vault.status()!!.state)
        assertEquals(Code.LOCKED, assertFailsWith<CoreException> { vault.codes() }.code)
        val wrong = assertFailsWith<CoreException> { vault.unlock("not the passphrase at all", secretKey) }
        assertEquals(Code.DENIED, wrong.code)
    }
}
