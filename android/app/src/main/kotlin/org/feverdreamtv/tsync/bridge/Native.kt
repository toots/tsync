package org.feverdreamtv.tsync.bridge

/** The core's JNI entry points (android.md §5). All text crosses as UTF-8 bytes. */
object Native {
    @JvmStatic external fun nativeInit(home: ByteArray, trustStore: ByteArray, transferRoot: ByteArray)
    @JvmStatic external fun nativeCheckConfig(domain: ByteArray, candidate: ByteArray?): ByteArray?
    @JvmStatic external fun nativeBoot(domain: ByteArray): ByteArray?
    @JvmStatic external fun nativeRequest(json: ByteArray): ByteArray
    @JvmStatic external fun nativeStatus(): ByteArray
    @JvmStatic external fun nativeOpen(ref: ByteArray): Long
    @JvmStatic external fun nativeSize(handle: Long): Long
    @JvmStatic external fun nativeRead(handle: Long, offset: Long, length: Int, dest: ByteArray): Int
    @JvmStatic external fun nativeClose(handle: Long): Int
    @JvmStatic external fun nativeNextNotice(): ByteArray
}
