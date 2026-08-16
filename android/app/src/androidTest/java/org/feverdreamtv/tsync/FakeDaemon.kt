package org.feverdreamtv.tsync

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import kotlin.concurrent.thread

/**
 * A daemon that only answers, for the parts of the app that cannot be reached
 * without one.
 *
 * Bound through a LocalSocket rather than by name: LocalServerSocket(String)
 * takes the abstract namespace, which [Ipc] never connects to, so a fake built
 * the obvious way is never reached and every test passes having exercised
 * nothing.
 */
class FakeDaemon(val socketFile: File) : Closeable {

    private val bound = LocalSocket(LocalSocket.SOCKET_STREAM)
    private val server: LocalServerSocket
    private val received = mutableListOf<JSONObject>()

    /** Answers ok to everything until a test says otherwise. */
    var answer: (JSONObject) -> JSONObject = { JSONObject().put("ok", true) }

    init {
        socketFile.parentFile?.mkdirs()
        socketFile.delete()
        bound.bind(
            LocalSocketAddress(socketFile.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM)
        )
        server = LocalServerSocket(bound.fileDescriptor)
        thread(isDaemon = true) { serve() }
    }

    val requests: List<JSONObject> get() = synchronized(received) { received.toList() }

    fun actions(): List<String> = requests.map { it.optString("action") }

    fun requestsFor(action: String): List<JSONObject> =
        requests.filter { it.optString("action") == action }

    private fun serve() {
        while (true) {
            val connection = runCatching { server.accept() }.getOrNull() ?: return
            thread(isDaemon = true) {
                connection.use { open ->
                    val reader = open.inputStream.bufferedReader()
                    while (true) {
                        val line = runCatching { reader.readLine() }.getOrNull() ?: return@use
                        val request = JSONObject(line)
                        synchronized(received) { received.add(request) }
                        val reply = runCatching { answer(request) }.getOrElse {
                            JSONObject().put("ok", false).put("error", it.message)
                        }
                        open.outputStream.write((reply.toString() + "\n").toByteArray())
                        open.outputStream.flush()
                    }
                }
            }
        }
    }

    fun notFound(): JSONObject =
        JSONObject().put("ok", false).put("code", "not_found").put("error", "no such key")

    override fun close() {
        runCatching { server.close() }
        runCatching { bound.close() }
        socketFile.delete()
    }
}
