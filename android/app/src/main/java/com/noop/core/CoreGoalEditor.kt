package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * The one-page goal editor of the shared core (`CoreGoalEditor.swift`, iOS's `CoachGoalEditorView`): Android holds the
 * [Draft] and hands it in with every call; the core loads the goal, applies the kind's date default, judges the pace
 * and the combined load, and saves through the shared goal store. Blocking JNI calls; run them off the main thread.
 */
object CoreGoalEditor {
    data class Draft(
        val kind: String = "run", val title: String = "", val baseline: String = "", val target: String = "",
        val hasTargetDate: Boolean = true, val targetDateTouched: Boolean = false, val targetDate: Double = 0.0,
        val motivation: String = "", val tags: List<String> = emptyList(), val share: Boolean = false, val reason: String = "",
    )
    data class State(
        val found: Boolean, val draft: Draft, val kinds: List<CoreGoalOnboarding.Kind>, val tags: List<Pair<String, String>>,
        val kindNote: String?, val quantified: Boolean, val placeholder: String,
        val rangeIsUsable: Boolean, val canSave: Boolean,
        val warning: String?, val veryAggressive: Boolean, val needsReason: Boolean, val volumeWarning: String?,
        val limit: String?, val replaceId: String?, val hasRoom: Boolean, val limitText: String?,
        val saved: Boolean, val labels: Map<String, String>,
    )

    /**
     * Loads goal [id] when [draft] is null, else judges [draft]; or first applies [op] (`kind` with [to], `save` with
     * [acknowledging] and [replacing]).
     */
    fun run(id: String, draft: Draft?, weightKg: Double, op: String? = null, to: String? = null,
            acknowledging: Boolean = false, replacing: String? = null): State? {
        if (!SwiftCore.available) return null
        val args = JSONObject().put("id", id).put("weightKg", weightKg).put("acknowledging", acknowledging)
        draft?.let {
            args.put("draft", JSONObject().put("kind", it.kind).put("title", it.title).put("baseline", it.baseline)
                .put("target", it.target).put("hasTargetDate", it.hasTargetDate).put("targetDateTouched", it.targetDateTouched)
                .put("targetDate", it.targetDate).put("motivation", it.motivation).put("tags", JSONArray(it.tags))
                .put("share", it.share).put("reason", it.reason))
        }
        to?.let { args.put("to", it) }
        replacing?.let { args.put("replacing", it) }
        val name = when {
            op != null -> "goals.editor.$op"
            draft == null -> "goals.editor.load"
            else -> "goals.editor"
        }
        val raw = SwiftCore.call(name, args.toString()) ?: return null
        return runCatching { parse(JSONObject(raw)) }.getOrNull()
    }

    internal fun parse(o: JSONObject): State {
        fun opt(k: String) = if (!o.has(k) || o.isNull(k)) null else o.optString(k).takeIf { it.isNotEmpty() }
        val d = o.getJSONObject("draft")
        val tagsIn = d.optJSONArray("tags")
        val draft = Draft(
            d.getString("kind"), d.optString("title"), d.optString("baseline"), d.optString("target"),
            d.optBoolean("hasTargetDate"), d.optBoolean("targetDateTouched"), d.optDouble("targetDate"),
            d.optString("motivation"), (0 until (tagsIn?.length() ?: 0)).map { tagsIn!!.getString(it) },
            d.optBoolean("share"), d.optString("reason"),
        )
        val k = o.getJSONArray("kinds")
        val t = o.getJSONArray("tags")
        val l = o.getJSONObject("labels")
        return State(
            o.optBoolean("found"), draft,
            (0 until k.length()).map { k.getJSONObject(it).let { x ->
                CoreGoalOnboarding.Kind(x.getString("id"), x.getString("label"), x.optString("blurb"), x.getBoolean("quantified"),
                                        x.optString("unit"), x.optString("placeholder")) } },
            (0 until t.length()).map { t.getJSONObject(it).let { x -> x.getString("id") to x.getString("label") } },
            opt("kindNote"), o.optBoolean("quantified"), o.optString("placeholder"),
            o.optBoolean("rangeIsUsable", true), o.optBoolean("canSave"),
            opt("warning"), o.optBoolean("veryAggressive"), o.optBoolean("needsReason"), opt("volumeWarning"),
            opt("limit"), opt("replaceId"), o.optBoolean("hasRoom", true), opt("limitText"),
            o.optBoolean("saved"), l.keys().asSequence().associateWith { l.getString(it) },
        )
    }
}
