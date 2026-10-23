package org.feverdreamtv.tsync.autofill

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import org.feverdreamtv.tsync.R
import org.json.JSONObject
import java.security.MessageDigest

/**
 * passwords/android §2: the browsers whose `webDomain` is believed, by package and signing
 * certificate. The list is Google's privileged-apps list for Credential Manager, bundled as is and
 * refreshed each release, so the same text answers `CallingAppInfo.getOrigin`.
 */
object Browsers {
    @Volatile
    private var text: String? = null

    /** The list in the privileged-apps JSON form. */
    fun json(context: Context): String = text ?: context.resources.openRawResource(R.raw.browsers)
        .use { it.readBytes().toString(Charsets.UTF_8) }.also { text = it }

    private fun fingerprints(context: Context, packageName: String): Set<String> {
        val apps = JSONObject(json(context)).getJSONArray("apps")
        for (i in 0 until apps.length()) {
            val info = apps.getJSONObject(i).getJSONObject("info")
            if (info.getString("package_name") != packageName) continue
            val signatures = info.getJSONArray("signatures")
            return (0 until signatures.length()).map { signatures.getJSONObject(it).getString("cert_fingerprint_sha256").uppercase() }.toSet()
        }
        return emptySet()
    }

    /** Whether [packageName] is installed, on the list, and signed by a certificate the list names. */
    fun isBrowser(context: Context, packageName: String): Boolean {
        val allowed = fingerprints(context, packageName)
        if (allowed.isEmpty()) return false
        return certificates(context, packageName).any { it in allowed }
    }

    /** passwords §4.3: an app's signing certificates as the package manager reports them, for its `android://` site. */
    fun certificatesOf(context: Context, site: String): List<String> =
        if (site.startsWith("android://")) certificates(context, site.removePrefix("android://")) else emptyList()

    @Suppress("DEPRECATION")
    private fun certificates(context: Context, packageName: String): List<String> = try {
        val manager = context.packageManager
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = manager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo
            when {
                info == null -> emptyArray()
                info.hasMultipleSigners() -> info.apkContentsSigners
                else -> info.signingCertificateHistory
            }
        } else {
            manager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures ?: emptyArray()
        }
        signatures.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString(":") { "%02X".format(it) }
        }
    } catch (e: PackageManager.NameNotFoundException) {
        emptyList()
    }
}
