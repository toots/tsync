package org.feverdreamtv.tsync.core

import java.io.File
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions

object Durable {
    private val ownerOnlyFile = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))
    private val ownerOnlyDir = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------"))
    const val TEMP_SUFFIX = ".tmp"

    fun fsync(file: File) {
        FileChannel.open(file.toPath(), StandardOpenOption.WRITE).use { it.force(true) }
    }

    fun fsyncDirectory(directory: File) {
        try {
            FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
        } catch (e: IOException) {
            // Some filesystems refuse to sync a directory; the rename is still atomic.
        }
    }

    fun privateDirectory(directory: File) {
        if (!directory.isDirectory) Files.createDirectories(directory.toPath(), ownerOnlyDir)
    }

    /** Temporary file created owner-only, fsync, rename, fsync of the directory (security-model §10.2). */
    fun write(file: File, content: ByteArray) {
        val temporary = File(file.parentFile, file.name + TEMP_SUFFIX)
        Files.deleteIfExists(temporary.toPath())
        Files.createFile(temporary.toPath(), ownerOnlyFile)
        FileChannel.open(temporary.toPath(), StandardOpenOption.WRITE).use { channel ->
            val buffer = java.nio.ByteBuffer.wrap(content)
            while (buffer.hasRemaining()) channel.write(buffer)
            channel.force(true)
        }
        rename(temporary, file)
    }

    fun rename(from: File, to: File) {
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        fsyncDirectory(to.parentFile)
    }

    fun delete(file: File) {
        if (Files.deleteIfExists(file.toPath())) fsyncDirectory(file.parentFile)
    }
}
