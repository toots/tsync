package org.feverdreamtv.tsync

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * What the linked domain needs from the app before it can serve: the trust
 * store, and the one way a request is sent and its reply read.
 */
object Tsync {
    const val TAG = "tsync"

    private val CA_DIRECTORIES = listOf(
        "/apex/com.android.conscrypt/cacerts",  // canonical since Android 14
        "/system/etc/security/cacerts"
    )

    /**
     * Concatenate the device's trust store into the single bundle file ca-certs
     * expects. Built from the system store rather than shipped in the APK so it
     * tracks the device's own roots instead of going stale.
     *
     * SSL_CERT_FILE is not optional. conduit forces its default authenticator
     * when it builds a context — for plain HTTP as much as for HTTPS — and
     * ca-certs only looks at /etc/ssl paths that Android does not have, so
     * without this the runtime dies at startup.
     *
     * Android's cert files carry human-readable text after the PEM block, so
     * only the blocks themselves are taken.
     */
    fun caBundle(context: Context): File {
        val bundle = File(context.filesDir, "ca-bundle.pem")
        if (bundle.exists() && bundle.length() > 0) return bundle

        val source = CA_DIRECTORIES.map(::File).firstOrNull { it.isDirectory }
        if (source == null) {
            Log.w(TAG, "no system CA directory found; TLS will not verify")
            return bundle
        }

        val begin = "-----BEGIN CERTIFICATE-----"
        val end = "-----END CERTIFICATE-----"
        bundle.bufferedWriter().use { out ->
            var count = 0
            source.listFiles()?.forEach { certificate ->
                runCatching {
                    val text = certificate.readText()
                    var from = text.indexOf(begin)
                    while (from >= 0) {
                        val to = text.indexOf(end, from)
                        if (to < 0) break
                        out.write(text.substring(from, to + end.length))
                        out.write("\n")
                        count++
                        from = text.indexOf(begin, to)
                    }
                }
            }
            Log.i(TAG, "CA bundle: $count certificates from $source")
        }
        return bundle
    }

    /** A request that answers in JSON. Throws [Cli.Error] on a refusal. */
    fun json(context: Context, request: String): JSONObject =
        Cli.reply(Native.request(context, request))
}
