package org.feverdreamtv.tsync

import android.content.Context
import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * Byte at a time: a body follows its header, and a reader that buffered ahead
 * into characters would eat the front of it.
 */
private fun readHeader(input: InputStream): String? {
    val line = ByteArrayOutputStream()
    while (true) {
        val b = input.read()
        if (b < 0) return if (line.size() == 0) null else line.toString()
        if (b == '\n'.code) return line.toString()
        line.write(b)
    }
}

/**
 * One process serving the ranges of one open file.
 *
 * An invocation per range costs its startup every time — about 100ms on a
 * Pixel 9a whatever it reads — and starts with nothing: the table that tells
 * lib/content/data.ml a read is sequential is empty, so the read-ahead it would
 * launch never fires, and would die with the process anyway. A process that
 * lasts as long as the open pays that once and lets the network run ahead of
 * the reader.
 *
 * The platform gives exactly this shape: openProxyFileDescriptor hands back a
 * callback that sees onGetSize, then reads, then onRelease.
 */
class ReadSession private constructor(
    private val process: Process,
    private val input: InputStream,
    private val output: OutputStream,
    val size: Long
) : Closeable {

    /**
     * Serves [length] bytes from [offset] into [into], answering short only at
     * the end of the content.
     *
     * Callers are the platform's proxy-descriptor callbacks, which arrive on one
     * handler thread; synchronized regardless, since a torn request and answer
     * would desynchronise the stream for every read after it.
     */
    @Synchronized
    fun read(offset: Long, length: Int, into: ByteArray): Int {
        output.write("$offset $length\n".toByteArray())
        output.flush()
        val header = readHeader(input) ?: throw Cli.Error("the session ended mid-read")
        val served = Cli.reply(header).getInt("length")
        var done = 0
        while (done < served) {
            val n = input.read(into, done, served - done)
            if (n < 0) throw Cli.Error("the session ended mid-body")
            done += n
        }
        return served
    }

    override fun close() {
        // Closing stdin is what ends it; destroy only if it will not go.
        runCatching { output.close() }
        runCatching {
            if (!process.waitFor(CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) process.destroy()
        }
        runCatching { input.close() }
        slots.release()
    }

    companion object {
        const val TAG = "tsyncsaf"
        private const val CLOSE_TIMEOUT_MS = 2_000L

        /**
         * How many opens may hold a process at once.
         *
         * A session lasts as long as its file is open, so these cannot come from
         * the pool that bounds one-shot calls: a few open files would take every
         * permit and the next stat would wait for a picker to be closed. Beyond
         * this a caller falls back to reading one range per invocation.
         */
        private const val MAX_SESSIONS = 4
        private val slots = Semaphore(MAX_SESSIONS)

        /** Null when no slot is free or the file would not open. */
        fun open(context: Context, key: String): ReadSession? {
            if (!slots.tryAcquire()) return null
            var process: Process? = null
            return try {
                process = Tsync.spawn(context, Cli.open(key))
                val input = BufferedInputStream(process.inputStream)
                val header = readHeader(input) ?: throw Cli.Error("no size line")
                ReadSession(process, input, process.outputStream, Cli.reply(header).getLong("size"))
            } catch (failure: Exception) {
                Log.w(TAG, "session $key: ${failure.message}")
                runCatching { process?.destroy() }
                slots.release()
                null
            }
        }
    }
}
