package org.feverdreamtv.tsync

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Semaphore

/**
 * Running the tsync binary.
 *
 * There is no daemon: each interaction with a domain is one invocation that does
 * that thing and exits. The binary ships as jniLibs/arm64-v8a/libtsync.so purely
 * so it lands in nativeLibraryDir, which is the only place an app may exec from
 * since API 29. It is an ordinary executable, not a shared object.
 */
object Tsync {
    const val TAG = "tsync"

    /**
     * How many invocations may run at once.
     *
     * The process is the unit of concurrency, and nothing else bounds it:
     * maxDownloads and the blocking pool are per process, so they cap what one
     * call does and say nothing about how many calls a picker starts. Each one
     * holds memory, descriptors and its own connections to the backends.
     */
    private const val MAX_CONCURRENT = 4
    private val slots = Semaphore(MAX_CONCURRENT, true)

    fun binary(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, "libtsync.so")

    /** Everything the binary locates — config, cache, data — hangs off HOME (see
     *  lib/platform/runtime/linux_runtime.ml), so one variable redirects it into
     *  the app sandbox. Not cacheDir: the OS may reap that while chunks are held.
     *
     *  SSL_CERT_FILE is not optional. conduit forces its default authenticator
     *  when it builds a context — for plain HTTP as much as for HTTPS — and
     *  ca-certs only looks at /etc/ssl paths that Android does not have, so
     *  without this every invocation dies at startup. */
    fun env(context: Context): Array<String> = arrayOf(
        "HOME=${context.filesDir.absolutePath}",
        "SSL_CERT_FILE=${caBundle(context).absolutePath}"
    )

    private val CA_DIRECTORIES = listOf(
        "/apex/com.android.conscrypt/cacerts",  // canonical since Android 14
        "/system/etc/security/cacerts"
    )

    /**
     * Concatenate the device's trust store into the single bundle file ca-certs
     * expects. Built from the system store rather than shipped in the APK so it
     * tracks the device's own roots instead of going stale.
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

    class Result(val code: Int, val out: ByteArray, val err: String) {
        val text: String get() = String(out)
    }

    /**
     * The slot is taken before the process, never after: a caller queueing for a
     * slot while already holding one would consume the thing the bound exists to
     * protect. stderr is drained on its own thread, a child that fills that pipe
     * blocking on the write and never reaching the exit this waits for.
     */
    fun run(context: Context, args: List<String>): Result {
        slots.acquire()
        try {
            val process = Runtime.getRuntime().exec(
                (listOf(binary(context).absolutePath) + args).toTypedArray(),
                env(context)
            )
            val errors = StringBuilder()
            val pump = Thread {
                runCatching {
                    process.errorStream.bufferedReader()
                        .forEachLine { errors.append(it).append('\n') }
                }
            }
            pump.start()
            // Bytes, not text: `read' answers with the file's own content.
            val out = ByteArrayOutputStream()
            process.inputStream.use { it.copyTo(out) }
            val code = process.waitFor()
            pump.join()
            val err = errors.toString()
            if (code != 0) {
                Log.w(TAG, "${args.joinToString(" ")} exited $code\n${err.trim()}")
            }
            return Result(code, out.toByteArray(), err)
        } finally {
            slots.release()
        }
    }

    /** A verb that answers in JSON. Throws [Cli.Error] on a refusal. */
    fun json(context: Context, args: List<String>): JSONObject =
        Cli.reply(run(context, args).text)

    /** A verb that answers in bytes. */
    fun bytes(context: Context, args: List<String>): ByteArray {
        val result = run(context, args)
        if (result.code != 0) throw Cli.Error(result.err.trim().takeLast(200))
        return result.out
    }

    /** A subcommand whose output a person reads: config, status, sync. */
    fun plain(context: Context, args: List<String>): Pair<Int, String> {
        val result = run(context, args)
        return result.code to (result.text + result.err)
    }

    fun plain(context: Context, vararg args: String): Pair<Int, String> =
        plain(context, args.toList())
}
