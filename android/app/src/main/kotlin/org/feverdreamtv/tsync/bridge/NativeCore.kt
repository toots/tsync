package org.feverdreamtv.tsync.bridge

import org.feverdreamtv.tsync.core.Core

object NativeCore : Core {
    private fun bytes(text: String) = text.toByteArray(Charsets.UTF_8)
    private fun text(bytes: ByteArray?) = bytes?.toString(Charsets.UTF_8)?.takeIf { it.isNotEmpty() }

    override fun checkConfig(domain: String, candidate: String?): String? =
        text(Native.nativeCheckConfig(bytes(domain), candidate?.let(::bytes)))
    override fun boot(domain: String): String? = text(Native.nativeBoot(bytes(domain)))
    override fun request(json: String): String = Native.nativeRequest(bytes(json)).toString(Charsets.UTF_8)
    override fun status(): String = Native.nativeStatus().toString(Charsets.UTF_8)
    override fun open(ref: String): Long = Native.nativeOpen(bytes(ref))
    override fun size(handle: Long): Long = Native.nativeSize(handle)
    override fun read(handle: Long, offset: Long, length: Int, dest: ByteArray): Int = Native.nativeRead(handle, offset, length, dest)
    override fun close(handle: Long): Int = Native.nativeClose(handle)
}
