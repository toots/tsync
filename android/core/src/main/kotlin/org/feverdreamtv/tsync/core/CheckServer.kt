package org.feverdreamtv.tsync.core

import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

data class ServerDomain(val name: String, val readOnly: Boolean)

sealed interface ServerAnswer {
    data class Domains(val domains: List<ServerDomain>) : ServerAnswer
    /** 401: the secret, or this device's clock. */
    data object SecretRefused : ServerAnswer
    /** 404: a server without the endpoint. */
    data object TooOld : ServerAnswer
    data class Failed(val reason: String) : ServerAnswer
}

/** The one request the app makes itself (app §6.2), signed as backends/http-proxy §3 specifies. */
object CheckServer {
    private const val API_PATH = "/domains"

    fun signature(secret: String, method: String, target: String, timestamp: String, body: ByteArray): String {
        val bodyHash = hex(MessageDigest.getInstance("SHA-256").digest(body))
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return hex(mac.doFinal("$method\n$target\n$timestamp\n$bodyHash".toByteArray(Charsets.UTF_8)))
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    /** Blocks for at most `check_server_timeout` per phase; never on the UI thread. */
    fun check(url: String, secret: String, nowSeconds: Long = System.currentTimeMillis() / 1000): ServerAnswer {
        val timestamp = nowSeconds.toString()
        return try {
            // The signature covers the API path only, never the base path.
            val connection = URI(url.trim().trimEnd('/') + API_PATH).toURL().openConnection() as HttpURLConnection
            connection.connectTimeout = Parameters.CHECK_SERVER_TIMEOUT_MS
            connection.readTimeout = Parameters.CHECK_SERVER_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("x-tsync-timestamp", timestamp)
            connection.setRequestProperty("x-tsync-signature", signature(secret, "GET", API_PATH, timestamp, ByteArray(0)))
            try {
                answer(connection)
            } finally {
                connection.disconnect()
            }
        } catch (e: IOException) {
            ServerAnswer.Failed(e.message ?: e.toString())
        } catch (e: RuntimeException) {
            ServerAnswer.Failed(e.message ?: e.toString())
        }
    }

    private fun answer(connection: HttpURLConnection): ServerAnswer = when (val status = connection.responseCode) {
        200 -> parse(connection.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8))
        401 -> ServerAnswer.SecretRefused
        404 -> ServerAnswer.TooOld
        else -> ServerAnswer.Failed("HTTP $status")
    }

    fun parse(body: String): ServerAnswer = try {
        val domains = JSONObject(body).getJSONArray("domains")
        ServerAnswer.Domains((0 until domains.length()).map {
            val domain = domains.getJSONObject(it)
            ServerDomain(domain.getString("name"), domain.optBoolean("readOnly", false))
        })
    } catch (e: JSONException) {
        ServerAnswer.Failed("the server's answer is not a list of domains")
    }
}
