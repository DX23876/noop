package com.noop.notif

import com.noop.R
import java.io.File

/**
 * The app's English strings, read from `values/strings.xml`, as the [NotifText] the notification copy takes, so a
 * JVM test reads exactly the words an English phone shows. A string the file lacks fails the test.
 */
object EnglishNotifText : NotifText {
    private val byName: Map<String, String> by lazy {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val xml = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
            .map { File(it, "android/app/src/main/res/values/strings.xml") }
            .plus(File(userDir, "src/main/res/values/strings.xml"))
            .first { it.isFile }.readText()
        Regex("""<string name="([^"]+)"[^>]*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL).findAll(xml)
            .associate { it.groupValues[1] to unescape(it.groupValues[2]) }
    }
    private val names: Map<Int, String> by lazy { R.string::class.java.fields.associate { it.getInt(null) to it.name } }

    override fun get(id: Int, vararg args: Any): String {
        val raw = byName[names[id]] ?: error("values/strings.xml has no string for id $id (${names[id]})")
        return if (args.isEmpty()) raw else String.format(java.util.Locale.ROOT, raw, *args)
    }

    private fun unescape(s: String) = s.replace("\\'", "'").replace("\\\"", "\"").replace("&amp;", "&")
        .replace("&lt;", "<").replace("&gt;", ">")
}
