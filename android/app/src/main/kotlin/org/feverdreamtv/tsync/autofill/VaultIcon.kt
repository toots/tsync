package org.feverdreamtv.tsync.autofill

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.Icon
import org.feverdreamtv.tsync.R
import org.feverdreamtv.tsync.Tsync

/** vault §8.1: the vault's icon, or tsync's glyph in the vault's colour; null without a vault. */
object VaultIcon {
    fun of(context: Context, tsync: Tsync): Icon? {
        val appearance = try {
            tsync.vault.status()?.appearance
        } catch (e: Exception) {
            null
        } ?: return null
        appearance.icon?.let { png -> BitmapFactory.decodeByteArray(png, 0, png.size)?.let { return Icon.createWithBitmap(it) } }
        val color = runCatching { Color.parseColor(appearance.color) }.getOrNull() ?: return null
        return Icon.createWithResource(context, R.drawable.ic_notification).setTint(color)
    }
}
