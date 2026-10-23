package org.feverdreamtv.tsync.autofill

import android.content.Context
import android.graphics.drawable.Icon
import org.feverdreamtv.tsync.R

/** vault §8.1: a suggestion carries tsync's own icon; the app serves one vault, whose mark is for its own screen. */
object TsyncIcon {
    fun of(context: Context): Icon = Icon.createWithResource(context, R.mipmap.ic_launcher)
}
