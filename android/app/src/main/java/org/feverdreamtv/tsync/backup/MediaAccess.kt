package org.feverdreamtv.tsync.backup

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * What the user has let the app see of the camera roll.
 *
 * Partial access is its own state, not a lesser kind of granted: on API 34 and
 * up the grant dialog offers "Select photos", and a backup that quietly covered
 * only the four the user picked would be worse than one that refused.
 */
object MediaAccess {

    enum class Level { FULL, SELECTED_ONLY, DENIED }

    fun level(context: Context): Level = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
            val images = granted(context, Manifest.permission.READ_MEDIA_IMAGES)
            val video = granted(context, Manifest.permission.READ_MEDIA_VIDEO)
            val selected = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                granted(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            when {
                images && video -> Level.FULL
                images || video || selected -> Level.SELECTED_ONLY
                else -> Level.DENIED
            }
        }

        granted(context, Manifest.permission.READ_EXTERNAL_STORAGE) -> Level.FULL
        else -> Level.DENIED
    }

    fun canRead(context: Context): Boolean = level(context) != Level.DENIED

    /** Everything the app should ask for, which the platform narrows by version
     *  on its own. */
    fun requested(): Array<String> = buildList {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.READ_MEDIA_IMAGES)
            add(Manifest.permission.READ_MEDIA_VIDEO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            }
        } else {
            add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            add(Manifest.permission.ACCESS_MEDIA_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }.toTypedArray()

    private fun granted(context: Context, permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
}
