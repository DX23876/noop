package com.noop.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * The guided goal setup of the shared core (`CoreGoalOnboarding.swift`, iOS's `GoalOnboardingDraft`): Android holds
 * the [Draft] and hands it in with every call; the core moves the step, applies the kind's defaults, checks the pace
 * and saves. Blocking JNI calls; run them off the main thread.
 */
object CoreGoalOnboarding {
    data class Draft(
        val step: Int = 0, val kind: String = "run", val title: String = "", val baseline: String = "", val target: String = "",
        val hasTargetDate: Boolean = true, val targetDateTouched: Boolean = false, val targetDate: Double = 0.0,
        val motivation: String = "", val tags: List<String> = emptyList(), val share: Boolean = false, val reason: String = "",
    )
    data class Kind(val id: String, val label: String, val blurb: String, val quantified: Boolean, val unit: String, val placeholder: String)
    data class State(
        val draft: Draft, val steps: Int, val stepTitle: String, val stepLabel: String,
        val canAdvance: Boolean, val rangeIsUsable: Boolean, val kinds: List<Kind>, val tags: List<Pair<String, String>>,
        val kindNote: String?, val goalTitle: String, val summary: String,
        val warning: String?, val veryAggressive: Boolean, val requiresReason: Boolean,
        val limit: String?, val replaceId: String?, val hasRoom: Boolean, val limitText: String?,
        val offer: Boolean, val saved: Boolean, val labels: Map<String, String>,
    )

    /**
     * Reads the wizard for [draft], or first applies [op] (`kind` with [to], `advance`, `back`, `commit` with
     * [acknowledging] and [replacing], `asked`).
     */
    fun run(draft: Draft, weightKg: Double, op: String? = null, to: String? = null,
            acknowledging: Boolean = false, replacing: String? = null): State? {
        if (!SwiftCore.available) return null
        val d = JSONObject().put("step", draft.step).put("kind", draft.kind).put("title", draft.title)
            .put("baseline", draft.baseline).put("target", draft.target).put("hasTargetDate", draft.hasTargetDate)
            .put("targetDateTouched", draft.targetDateTouched).put("targetDate", draft.targetDate)
            .put("motivation", draft.motivation).put("tags", JSONArray(draft.tags)).put("share", draft.share)
            .put("reason", draft.reason)
        val args = JSONObject().put("draft", d).put("weightKg", weightKg).put("acknowledging", acknowledging)
        to?.let { args.put("to", it) }
        replacing?.let { args.put("replacing", it) }
        val raw = SwiftCore.call(if (op == null) "goals.onboarding" else "goals.onboarding.$op", args.toString()) ?: return null
        return runCatching { parse(JSONObject(raw)) }.getOrNull()
    }

    internal fun parse(o: JSONObject): State {
        fun opt(k: String) = if (!o.has(k) || o.isNull(k)) null else o.optString(k).takeIf { it.isNotEmpty() }
        val d = o.getJSONObject("draft")
        val tagsIn = d.optJSONArray("tags")
        val draft = Draft(
            d.getInt("step"), d.getString("kind"), d.optString("title"), d.optString("baseline"), d.optString("target"),
            d.optBoolean("hasTargetDate"), d.optBoolean("targetDateTouched"), d.optDouble("targetDate"),
            d.optString("motivation"), (0 until (tagsIn?.length() ?: 0)).map { tagsIn!!.getString(it) },
            d.optBoolean("share"), d.optString("reason"),
        )
        val k = o.getJSONArray("kinds")
        val t = o.getJSONArray("tags")
        val l = o.getJSONObject("labels")
        return State(
            draft, o.getInt("steps"), o.getString("stepTitle"), o.getString("stepLabel"),
            o.getBoolean("canAdvance"), o.getBoolean("rangeIsUsable"),
            (0 until k.length()).map { k.getJSONObject(it).let { x ->
                Kind(x.getString("id"), x.getString("label"), x.optString("blurb"), x.getBoolean("quantified"),
                     x.optString("unit"), x.optString("placeholder")) } },
            (0 until t.length()).map { t.getJSONObject(it).let { x -> x.getString("id") to x.getString("label") } },
            opt("kindNote"), o.getString("goalTitle"), o.getString("summary"),
            opt("warning"), o.optBoolean("veryAggressive"), o.optBoolean("requiresReason"),
            opt("limit"), opt("replaceId"), o.optBoolean("hasRoom", true), opt("limitText"),
            o.optBoolean("offer"), o.optBoolean("saved"), l.keys().asSequence().associateWith { l.getString(it) },
        )
    }
}
