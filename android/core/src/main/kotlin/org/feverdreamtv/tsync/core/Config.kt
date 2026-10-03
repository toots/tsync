package org.feverdreamtv.tsync.core

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.net.URISyntaxException

/** What the app configures: one domain backed by one http-proxy server (app §6.1). */
data class ServerConfig(
    val url: String,
    val secret: String,
    val domain: String,
    val maxCache: String = Parameters.DEFAULT_MAX_CACHE,
) {
    fun encode(clientName: String): String {
        val backend = JSONObject().put("type", "http-proxy").put("name", "server").put("role", "main")
            .put("url", url.trim().trimEnd('/')).put("secret", secret)
        val domain = JSONObject().put("name", domain).put("versioning", true).put("symlinks", "skip")
            .put("maxCache", maxCache.trim()).put("frontends", JSONArray().put("android"))
            .put("backends", JSONArray().put(backend))
        return JSONObject().put("name", clientName).put("domains", JSONArray().put(domain)).toString()
    }

    companion object {
        /** Reads what a config names, leniently: it prefills a form, it validates nothing. */
        fun decode(text: String): Pair<String?, ServerConfig>? = try {
            val config = JSONObject(text)
            val domain = config.getJSONArray("domains").getJSONObject(0)
            val backends = domain.optJSONArray("backends") ?: JSONArray()
            val backend = (0 until backends.length()).map { backends.getJSONObject(it) }
                .firstOrNull { it.optString("type", "") == "http-proxy" } ?: JSONObject()
            val maxCache = if (domain.has("maxCache")) domain.get("maxCache").toString() else ""
            text(config, "name") to ServerConfig(
                url = backend.optString("url", ""),
                secret = backend.optString("secret", ""),
                domain = domain.optString("name", ""),
                maxCache = maxCache,
            )
        } catch (e: JSONException) {
            null
        }
    }
}

enum class FormField { URL, SECRET, DOMAIN }

enum class FormError(val field: FormField) {
    URL_MALFORMED(FormField.URL),
    URL_CLEARTEXT(FormField.URL),
    SECRET_TOO_SHORT(FormField.SECRET),
    DOMAIN_INVALID(FormField.DOMAIN),
}

object ConfigForm {
    private val reservedDomains = setOf("shares", "corrupted", "verify-jobs", "gc-jobs")

    /** app §6.1 rules 1–3: the first failure wins. Rule 4 is the core's. */
    fun validate(config: ServerConfig): FormError? =
        urlError(config.url)
            ?: FormError.SECRET_TOO_SHORT.takeIf { config.secret.length < Parameters.MIN_SECRET_LENGTH }
            ?: FormError.DOMAIN_INVALID.takeIf { !isDomainName(config.domain) }

    fun urlError(url: String): FormError? {
        val uri = try {
            URI(url.trim())
        } catch (e: URISyntaxException) {
            return FormError.URL_MALFORMED
        }
        val host = uri.host ?: return FormError.URL_MALFORMED
        if (uri.userInfo != null || uri.rawQuery != null || uri.rawFragment != null) return FormError.URL_MALFORMED
        return when (uri.scheme?.lowercase()) {
            "https" -> null
            "http" -> if (isLoopback(host)) null else FormError.URL_CLEARTEXT
            else -> FormError.URL_MALFORMED
        }
    }

    fun isLoopback(host: String): Boolean {
        val bare = host.removePrefix("[").removeSuffix("]").lowercase()
        if (bare == "localhost" || bare == "::1") return true
        val octets = bare.split('.').map { it.toIntOrNull() }
        return octets.size == 4 && octets.all { it != null && it in 0..255 } && octets[0] == 127
    }

    /** The grammar of 01-core §2.2, on the name's bytes. */
    fun isDomainName(name: String): Boolean {
        val bytes = name.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > 255) return false
        if (bytes.any { it.toInt() in 0x00..0x1F || it.toInt() == 0x7F || it.toInt() == '/'.code }) return false
        return name != "." && name != ".." && !name.startsWith(".tsync-") && name !in reservedDomains
    }
}

/** The config file (app §6.1): only a text the core accepted is ever written to it. */
class ConfigStore(home: File) {
    private val directory = File(home, ".config/tsync")
    val file = File(directory, "config.json")

    fun exists(): Boolean = file.exists()

    fun read(): ServerConfig? = decoded()?.second

    private fun decoded(): Pair<String?, ServerConfig>? =
        if (exists()) ServerConfig.decode(file.readText()) else null

    /**
     * @param check the core's `check_config` of a domain and a candidate text: null when accepted
     * @return null when the candidate became the config, else the core's sentence
     */
    @Synchronized
    fun save(config: ServerConfig, deviceName: String, check: (String, String) -> String?): String? {
        val clientName = decoded()?.first?.takeIf { it.isNotEmpty() } ?: deviceName.ifBlank { "android" }
        val candidate = config.encode(clientName)
        check(config.domain, candidate)?.let { return it }
        Durable.privateDirectory(directory)
        Durable.write(file, candidate.toByteArray())
        return null
    }
}
