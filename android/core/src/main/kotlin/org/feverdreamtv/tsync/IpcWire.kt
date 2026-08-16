package org.feverdreamtv.tsync

import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStream
import java.io.OutputStream

/**
 * The daemon's protocol: one JSON object per line, one reply per request.
 *
 * Kept clear of LocalSocket, which exists only on a device, so the framing and
 * the field names can be driven against a real daemon from a JVM test — that
 * being the seam that drifts, the two sides agreeing on it by having the same
 * strings written out in OCaml and in Kotlin.
 */
object IpcWire {

    class Error(message: String) : Exception(message)

    /** Values are typed: the daemon reads offsets and lengths as JSON numbers
     *  and ignores a string spelling of one. */
    fun request(action: String, fields: Map<String, Any>): JSONObject {
        val request = JSONObject().put("action", action)
        fields.forEach { (key, value) -> request.put(key, value) }
        return request
    }

    /**
     * Writing does not half-close the connection, the daemon answering each
     * newline-framed line as it arrives (lib/transport/ipc/ipc.ml).
     */
    fun wire(input: InputStream, output: OutputStream, request: JSONObject): JSONObject {
        output.write((request.toString() + "\n").toByteArray())
        output.flush()

        val line = BufferedReader(input.reader()).readLine()
            ?: throw Error("daemon closed the connection without replying")
        val response = JSONObject(line)
        if (!response.optBoolean("ok")) {
            throw Error(response.optString("error", "request failed: ${request.opt("action")}"))
        }
        return response
    }
}
