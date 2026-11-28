package com.noop.notif

import android.content.Context

/**
 * A string resource with its arguments: the app's own resources in the app ([of]), the English `strings.xml` in
 * the JVM tests. The notification copy functions take one, so they stay plain code and still speak the wearer's
 * language; they used to build English sentences in code, which every locale then received (found 2026-11-28).
 */
fun interface NotifText {
    fun get(id: Int, vararg args: Any): String

    companion object {
        fun of(context: Context): NotifText = NotifText { id, args -> context.getString(id, *args) }
    }
}
