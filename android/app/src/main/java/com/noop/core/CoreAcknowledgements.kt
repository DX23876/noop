package com.noop.core

import org.json.JSONObject

/**
 * Fork (DX23876), Settings parity package 6 (SUB-10, ABT-03): the credit list of Settings › About ›
 * Acknowledgements, read from the shared core (`about.acknowledgements`, the Swift `Acknowledgements` in
 * StrandCore), so the Apple screen and this one show one list. The licence texts the rows open are the files of
 * `Strand/Resources/ThirdParty/`, packed as assets; the core only names them.
 */
object CoreAcknowledgements {
    /** Third-party content or the media note: a title, what it is used for and an optional link. */
    data class Entry(val title: String, val detail: String, val link: String?)

    /** A library or ported code whose licence text ships with the app (`<resource>.txt` in the assets). */
    data class License(val title: String, val detail: String, val link: String, val fileLabel: String, val resource: String)

    /** A person or project whose work the fork adopted. */
    data class Person(val handle: String, val work: String)

    data class Credits(
        val content: List<Entry>,
        val licenses: List<License>,
        val media: Entry,
        val contributors: List<Person>,
        val attributionUrl: String,
    )

    /** The list, or null when this build has no core. */
    fun credits(): Credits? = runCatching {
        parse(JSONObject(SwiftCore.call("about.acknowledgements", "{}") ?: return@runCatching null))
    }.getOrNull()

    internal fun parse(root: JSONObject): Credits {
        fun entry(o: JSONObject) = Entry(o.getString("title"), o.getString("detail"), o.optString("link").ifEmpty { null })
        fun <T> list(key: String, make: (JSONObject) -> T): List<T> =
            root.getJSONArray(key).let { rows -> (0 until rows.length()).map { make(rows.getJSONObject(it)) } }
        return Credits(
            content = list("content", ::entry),
            licenses = list("licenses") {
                License(it.getString("title"), it.getString("detail"), it.getString("link"),
                        it.getString("fileLabel"), it.getString("resource"))
            },
            media = entry(root.getJSONObject("media")),
            contributors = list("contributors") { Person(it.getString("handle"), it.getString("work")) },
            attributionUrl = root.getString("attributionUrl"),
        )
    }
}
