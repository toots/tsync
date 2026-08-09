package org.feverdreamtv.tsync

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The one request the app makes for itself, because it happens before there is a
 * config for a daemon to run against. Same HMAC the daemon signs with — see
 * `Http_proxy.Auth` in lib/http_proxy/http_proxy.ml.
 */
object Server {
    private const val PATH = "/domains"

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    private fun signature(secret: String, timestamp: String): String {
        val body = hex(MessageDigest.getInstance("SHA-256").digest(ByteArray(0)))
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.toByteArray(), "HmacSHA256"))
        return hex(mac.doFinal("GET\n$PATH\n$timestamp\n$body".toByteArray()))
    }

    /**
     * Domains this server serves to holders of this secret. The failure carries a
     * message meant for the form: the whole point of asking is to tell the user
     * which of the three fields is wrong before anything is saved.
     */
    fun domains(url: String, secret: String): Result<List<String>> = runCatching {
        // The daemon signs seconds since the epoch and rejects a skew over 5
        // minutes, so a device with the wrong clock fails as unauthorized.
        val timestamp = (System.currentTimeMillis() / 1000).toString()
        val conn = URL(url.trimEnd('/') + PATH).openConnection() as HttpURLConnection
        conn.connectTimeout = 10_000
        conn.readTimeout = 10_000
        conn.setRequestProperty("x-tsync-timestamp", timestamp)
        conn.setRequestProperty("x-tsync-signature", signature(secret, timestamp))
        try {
            when (val code = conn.responseCode) {
                200 -> {
                    val list = JSONObject(conn.inputStream.reader().readText())
                        .getJSONArray("domains")
                    (0 until list.length()).map { list.getJSONObject(it).getString("name") }
                }
                401 -> error("the secret was refused (or this device's clock is off)")
                404 -> error("no tsync proxy answering at that URL")
                else -> error("the server answered HTTP $code")
            }
        } finally {
            conn.disconnect()
        }
    }
}
