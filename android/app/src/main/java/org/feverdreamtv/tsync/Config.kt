package org.feverdreamtv.tsync

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The daemon's config.json, written where HOME-relative path derivation expects
 * it (lib/runtime/linux_runtime.ml).
 *
 * Deliberately not a general editor: v1 configures one domain backed by one
 * http-proxy server. `tsync config --edit` already covers the general case on
 * desktop, and its field_spec registry is what a generated form would be built
 * from if a second backend type ever shows up here.
 */
object Config {
    /** The domain name rides in the socket filename, and sockaddr_un caps the
     *  whole path at 108 bytes. The prefix here is ~67, so this leaves room. */
    const val MAX_DOMAIN_LENGTH = 32

    data class Settings(
        val domain: String,
        val url: String,
        val secret: String,
        val maxCache: String
    )

    fun file(context: Context): File =
        File(context.filesDir, ".config/tsync/config.json")

    fun exists(context: Context) = file(context).isFile

    fun load(context: Context): Settings? {
        val json = runCatching { JSONObject(file(context).readText()) }.getOrNull() ?: return null
        val domain = json.optJSONArray("domains")?.optJSONObject(0) ?: return null
        val backend = domain.optJSONArray("backends")?.optJSONObject(0) ?: return null
        return Settings(
            domain = domain.optString("name"),
            url = backend.optString("url"),
            secret = backend.optString("secret"),
            maxCache = domain.optString("maxCache", "2G")
        )
    }

    enum class Field { DOMAIN, URL, SECRET }

    data class Problem(val field: Field, val message: String)

    /** The first problem, naming the field it belongs to so the form can put
     *  the message where the user is looking. Only checks what the daemon
     *  cannot report usefully itself. */
    fun validate(settings: Settings): Problem? = when {
        settings.domain.isBlank() ->
            Problem(Field.DOMAIN, "Domain name is required")
        settings.domain.length > MAX_DOMAIN_LENGTH ->
            Problem(Field.DOMAIN, "Domain name must be at most $MAX_DOMAIN_LENGTH characters " +
                "(it goes in the socket path, which the OS caps)")
        // Spaces are fine — "Jellyfin Media" is a real domain name. Only the
        // path separator is out: the name lands in a socket filename.
        settings.domain.any { it == '/' || it.isISOControl() } ->
            Problem(Field.DOMAIN, "Domain name cannot contain '/'")
        settings.url.isBlank() ->
            Problem(Field.URL, "Server URL is required")
        !settings.url.startsWith("http://") && !settings.url.startsWith("https://") ->
            Problem(Field.URL, "Server URL must start with http:// or https://")
        settings.secret.isBlank() ->
            Problem(Field.SECRET, "Shared secret is required")
        else -> null
    }

    fun save(context: Context, settings: Settings) {
        val backend = JSONObject()
            .put("type", "http-proxy")
            .put("name", "server")
            .put("role", "main")
            .put("url", settings.url)
            .put("secret", settings.secret)

        val domain = JSONObject()
            .put("name", settings.domain)
            .put("versioning", true)
            // SAF has no symlink concept, so there is nothing to represent one as.
            .put("symlinks", "skip")
            .put("maxCache", settings.maxCache)
            .put("frontends", JSONArray().put("android"))
            .put("backends", JSONArray().put(backend))

        val config = JSONObject()
            .put("name", android.os.Build.MODEL ?: "android")
            .put("domains", JSONArray().put(domain))

        file(context).apply {
            parentFile?.mkdirs()
            writeText(config.toString(2))
        }
    }
}
