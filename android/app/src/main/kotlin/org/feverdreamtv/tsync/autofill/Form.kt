package org.feverdreamtv.tsync.autofill

import android.app.assist.AssistStructure
import android.content.Context
import android.text.InputType
import android.util.Log
import android.view.View
import android.view.autofill.AutofillId

/** The fields of one fill request (passwords/android §3–§5), and who it is for (§2). */
class Form(
    val site: String,
    val username: List<AutofillId>,
    val password: List<AutofillId>,
    val code: List<AutofillId>,
    /** What the user typed, for a save request. */
    val typedUsername: String?,
    val typedPassword: String?,
) {
    val ids: List<AutofillId> get() = username + password + code

    companion object {
        private const val TAG = "tsync-autofill"
        private val CODE_NAMES = listOf("otp", "totp", "2fa", "one-time", "onetime", "mfa", "verification-code", "verification_code")

        /**
         * §2: the page's origin only when a browser of the list asks; any other app is its
         * package, whatever `webDomain` it declares.
         */
        fun of(context: Context, structure: AssistStructure): Form? {
            val packageName = structure.activityComponent.packageName
            val walk = Walk()
            for (i in 0 until structure.windowNodeCount) walk.visit(structure.getWindowNodeAt(i).rootViewNode)
            if (walk.username.isEmpty() && walk.password.isEmpty() && walk.code.isEmpty()) return null
            val domain = walk.webDomain
            val site = if (domain != null && Browsers.isBrowser(context, packageName)) {
                "${walk.webScheme ?: "https"}://$domain"
            } else {
                "android://$packageName"
            }
            return Form(site, walk.username, walk.password, walk.code, walk.typedUsername, walk.typedPassword)
        }
    }

    private class Walk {
        val username = mutableListOf<AutofillId>()
        val password = mutableListOf<AutofillId>()
        val code = mutableListOf<AutofillId>()
        var webDomain: String? = null
        var webScheme: String? = null
        var typedUsername: String? = null
        var typedPassword: String? = null

        fun visit(node: AssistStructure.ViewNode) {
            node.webDomain?.takeIf { it.isNotBlank() && webDomain == null }?.let {
                webDomain = it
                webScheme = node.webScheme?.takeIf { scheme -> scheme == "http" || scheme == "https" }
            }
            node.autofillId?.let { id ->
                when (kind(node)) {
                    Kind.USERNAME -> { username += id; if (typedUsername == null) typedUsername = typed(node) }
                    Kind.PASSWORD -> { password += id; if (typedPassword == null) typedPassword = typed(node) }
                    Kind.CODE -> code += id
                    null -> {}
                }
            }
            for (i in 0 until node.childCount) visit(node.getChildAt(i))
        }

        private fun typed(node: AssistStructure.ViewNode): String? =
            node.autofillValue?.takeIf { it.isText }?.textValue?.toString()?.takeIf { it.isNotEmpty() }

        /**
         * Autofill hints first, then the HTML attributes a browser reports, then the input type.
         * A code field is also told by its name: browsers pass `autocomplete` on unevenly.
         */
        private fun kind(node: AssistStructure.ViewNode): Kind? {
            if (node.autofillType != View.AUTOFILL_TYPE_TEXT) return null
            val hints = node.autofillHints.orEmpty().map { it.lowercase() }.toMutableList()
            val names = mutableListOf<String>()
            node.htmlInfo?.attributes?.forEach { attribute ->
                val value = attribute.second.orEmpty().lowercase()
                when (attribute.first) {
                    "autocomplete", "ua-autofill-hints", "computed-autofill-hints" -> hints += value.split(' ', ',')
                    "type" -> if (value == "password") hints += "password"
                    "name", "id" -> names += value
                }
            }
            node.idEntry?.let { names += it.lowercase() }
            // Names and hints only, never a value: what to look at when a field is missed.
            Log.d(TAG, "field hints=$hints names=$names inputType=${node.inputType} html=${node.htmlInfo?.attributes?.map { it.first }}")
            return when {
                hints.any { it == View.AUTOFILL_HINT_PASSWORD.lowercase() || it == "current-password" || it == "new-password" } -> Kind.PASSWORD
                hints.any { it == "one-time-code" || it.startsWith("smsotpcode") || it.contains("otp") } -> Kind.CODE
                names.any { name -> CODE_NAMES.any { name.contains(it) } } -> Kind.CODE
                hints.any {
                    it == View.AUTOFILL_HINT_USERNAME.lowercase() || it == View.AUTOFILL_HINT_EMAIL_ADDRESS.lowercase() ||
                        it == "username" || it == "email"
                } -> Kind.USERNAME
                isPasswordInput(node.inputType) -> Kind.PASSWORD
                node.inputType and InputType.TYPE_MASK_VARIATION == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS -> Kind.USERNAME
                else -> null
            }
        }

        private fun isPasswordInput(type: Int): Boolean {
            val variation = type and InputType.TYPE_MASK_VARIATION
            return (type and InputType.TYPE_MASK_CLASS == InputType.TYPE_CLASS_TEXT) &&
                (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
        }
    }

    private enum class Kind { USERNAME, PASSWORD, CODE }
}
