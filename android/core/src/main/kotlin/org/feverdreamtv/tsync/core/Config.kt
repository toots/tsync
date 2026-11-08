package org.feverdreamtv.tsync.core

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File

/** One domain the app configures, backed by one http-proxy server (app §6.1). */
data class ServerConfig(
    val url: String,
    val secret: String,
    val domain: String,
    val maxCache: String = Parameters.DEFAULT_MAX_CACHE,
) {
    private fun json(): JSONObject {
        val backend = JSONObject().put("type", "http-proxy").put("name", "server").put("role", "main")
            .put("url", url.trim().trimEnd('/')).put("secret", secret)
        return JSONObject().put("name", domain).put("versioning", true)
            .put("maxCache", maxCache.trim()).put("frontends", JSONArray().put("android"))
            .put("backends", JSONArray().put(backend))
    }

    companion object {
        fun encode(clientName: String, domains: List<ServerConfig>): String =
            JSONObject().put("name", clientName).put("domains", JSONArray(domains.map { it.json() })).toString()

        /** Reads what a config names, leniently: it lists domains, it validates nothing. */
        fun decode(text: String): Pair<String?, List<ServerConfig>>? = try {
            val config = JSONObject(text)
            val domains = config.getJSONArray("domains")
            text(config, "name") to (0 until domains.length()).map { domain(domains.getJSONObject(it)) }
        } catch (e: JSONException) {
            null
        }

        private fun domain(domain: JSONObject): ServerConfig {
            val backends = domain.optJSONArray("backends") ?: JSONArray()
            val backend = (0 until backends.length()).map { backends.getJSONObject(it) }
                .firstOrNull { it.optString("type", "") == "http-proxy" } ?: JSONObject()
            val maxCache = if (domain.has("maxCache")) domain.get("maxCache").toString() else ""
            return ServerConfig(
                url = backend.optString("url", ""),
                secret = backend.optString("secret", ""),
                domain = domain.optString("name", ""),
                maxCache = maxCache,
            )
        }
    }
}

/**
 * The config file (app §6.1): only a text the core accepted is ever written to it. [check] is the
 * core's `check_config` of a domain and a candidate text, null when accepted.
 */
class ConfigStore(home: File) {
    private val directory = File(home, ".config/tsync")
    val file = File(directory, "config.json")

    fun exists(): Boolean = file.exists()

    /** The configured domains, in the order the app lists them; empty when there is none. */
    fun read(): List<ServerConfig> = decoded()?.second.orEmpty()

    fun names(): List<String> = read().map { it.domain }

    /** A config file that does not decode: Setup replaces it (app §10.2). */
    fun unreadable(): Boolean = exists() && decoded() == null

    private fun decoded(): Pair<String?, List<ServerConfig>>? =
        if (exists()) ServerConfig.decode(file.readText()) else null

    /**
     * Appends [added], leaving out a domain the config already names. With [replace] the current
     * domains are dropped, as Setup does over a config that does not load (app §10.2).
     * @return null when the candidate became the config, else the refused domain and the core's sentence
     */
    @Synchronized
    fun add(added: List<ServerConfig>, deviceName: String, replace: Boolean = false, check: (String, String) -> String?): String? {
        val current = decoded()
        val kept = if (replace) emptyList() else current?.second.orEmpty()
        val fresh = added.filter { new -> kept.none { it.domain == new.domain } }
        val clientName = current?.first?.takeIf { it.isNotEmpty() } ?: deviceName.ifBlank { "android" }
        val candidate = ServerConfig.encode(clientName, kept + fresh)
        for (domain in fresh) check(domain.domain, candidate)?.let { return "${domain.domain}: $it" }
        write(candidate)
        return null
    }

    /** Deletes [name]'s entry and nothing else. @return the core's sentence when it refuses what is left */
    @Synchronized
    fun remove(name: String, check: (String, String) -> String?): String? {
        val (clientName, domains) = decoded() ?: return null
        val kept = domains.filter { it.domain != name }
        val candidate = ServerConfig.encode(clientName ?: "android", kept)
        kept.firstOrNull()?.let { first -> check(first.domain, candidate)?.let { return it } }
        write(candidate)
        return null
    }

    private fun write(candidate: String) {
        Durable.privateDirectory(directory)
        Durable.write(file, candidate.toByteArray())
    }
}
