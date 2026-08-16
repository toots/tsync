package org.feverdreamtv.tsync

import java.io.File

/**
 * Where the daemon puts things, given the HOME it was started with.
 *
 * Mirrors Runtime.default_paths in lib/platform/runtime/linux_runtime.ml, which
 * is what the Android build runs. It sits here rather than beside the socket
 * code so the protocol test reaches the same spelling instead of a second one
 * that agrees until it does not.
 */
object DaemonPaths {
    fun socket(home: File, domain: String): File =
        File(home, ".local/share/tsync/tsync-$domain.sock")

    fun config(home: File): File = File(home, ".config/tsync/config.json")
}
