package org.feverdreamtv.tsync.core

import org.json.JSONException
import org.json.JSONObject
import java.util.Base64

/** A domain a setup link offers, with the server it is reached through and its vault's look (setup-link §4). */
class SetupDomain(val name: String, val url: String, val secret: String, val look: Appearance?)

sealed interface SetupAnswer {
    class Opened(val from: String, val domains: List<SetupDomain>, val skipped: List<String>) : SetupAnswer
    class Refused(val reason: String) : SetupAnswer
}

object SetupLink {
    fun parse(json: String): SetupAnswer = try {
        val answer = JSONObject(json)
        if (answer.has("error")) SetupAnswer.Refused(answer.getString("error"))
        else {
            val about = answer.optJSONArray("about")
            val looks = (0 until (about?.length() ?: 0)).associate { i ->
                val a = about!!.getJSONObject(i)
                a.getString("name") to a.optJSONObject("vault")
            }
            val domains = answer.getJSONArray("domains")
            val skipped = answer.getJSONArray("skipped")
            SetupAnswer.Opened(
                answer.optString("from"),
                (0 until domains.length()).map { i ->
                    val d = domains.getJSONObject(i)
                    val vault = looks[d.getString("name")]
                    SetupDomain(
                        d.getString("name"), d.getString("url"), d.getString("secret"),
                        vault?.let { v ->
                            v.optString("color").takeIf { it.isNotEmpty() }?.let { color ->
                                val icon = v.optString("icon").takeIf { it.isNotEmpty() }
                                Appearance(color, true, icon?.let { runCatching { Base64.getDecoder().decode(it) }.getOrNull() })
                            }
                        },
                    )
                },
                (0 until skipped.length()).map { i ->
                    val s = skipped.getJSONObject(i)
                    "${s.getString("name")}: ${s.getString("reason")}"
                },
            )
        }
    } catch (e: JSONException) {
        SetupAnswer.Refused(e.message ?: "unreadable answer")
    }
}
