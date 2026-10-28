package com.noop.core

import android.content.Context
import com.noop.ai.AiProvider
import com.noop.ai.ChatMsg
import com.noop.ai.CustomAiAuthHeader
import org.json.JSONObject

/**
 * The shared coach in the Swift core (`CoreCoach.swift`, the Apple app's `AICoachEngine`): Android hands in its
 * settings and the key from its encrypted store, starts a reply, and reads the transcript back while it streams.
 * Blocking JNI calls; run them off the main thread.
 */
object CoreCoach {
    data class State(val messages: List<ChatMsg>, val sending: Boolean, val error: String?, val configured: Boolean,
                     val name: String = "")

    data class Settings(
        val provider: AiProvider, val model: String, val key: String, val consent: Boolean,
        val customBaseUrl: String, val customAuthHeader: CustomAiAuthHeader, val customConnected: Boolean,
    )

    /** Hands the settings and the key to the shared coach; true when it can reach the provider. */
    fun configure(context: Context, settings: Settings, dismissedWorkouts: List<String>): Boolean {
        val args = JSONObject(CoreGoals.settings(context, dismissedWorkouts))
            .put("provider", providerId(settings.provider)).put("model", settings.model).put("key", settings.key)
            .put("consent", settings.consent).put("customBaseUrl", settings.customBaseUrl)
            .put("customAuthHeader", if (settings.customAuthHeader == CustomAiAuthHeader.X_API_KEY) "xAPIKey" else "bearer")
            .put("customConnected", settings.customConnected)
            .put("enabled", com.noop.ui.NoopPrefs.coachEnabled(context))
        return call("coach.configure", args.toString())?.optBoolean("configured") ?: false
    }

    fun send(text: String): Boolean = call("coach.send", JSONObject().put("text", text).toString())?.optBoolean("ok") ?: false

    fun state(): State? = call("coach.state", "{}")?.let(::parse)

    fun newConversation(): State? = call("coach.new", "{}")?.let(::parse)

    fun stop(): State? = call("coach.stop", "{}")?.let(::parse)

    /** The coach's identity (`CoachIdentity`): name, picture and tone, edited on Android as on iOS. */
    data class Identity(val name: String, val avatarKind: String, val avatarValue: String, val voice: String,
                        val symbols: List<String>)

    fun identity(): Identity? = call("coach.identity", "{}")?.let(::parseIdentity)

    /** Applies a preset (`svea`, `marv`) first, then any of name, tone and picture; returns the identity after. */
    fun setIdentity(preset: String? = null, name: String? = null, voice: String? = null,
                    avatarKind: String? = null, avatarValue: String? = null): Identity? {
        val args = JSONObject()
        preset?.let { args.put("preset", it) }
        name?.let { args.put("name", it) }
        voice?.let { args.put("voice", it) }
        if (avatarKind != null && avatarValue != null) args.put("avatarKind", avatarKind).put("avatarValue", avatarValue)
        return call("coach.identity.set", args.toString())?.let(::parseIdentity)
    }

    internal fun parseIdentity(o: JSONObject): Identity? {
        if (!o.has("name")) return null
        val s = o.optJSONArray("symbols")
        return Identity(o.getString("name"), o.optString("avatarKind"), o.optString("avatarValue"), o.optString("voice"),
                        (0 until (s?.length() ?: 0)).map { s!!.getString(it) })
    }

    /** The coaching and data-access settings (`CoachSettingsView`), every label worded by the core from iOS. */
    data class Choice(val id: String, val label: String, val detail: String)
    data class Purpose(val id: String, val label: String, val detail: String, val on: Boolean)
    data class CoachSettings(
        val persona: String, val personas: List<Choice>, val verbosity: String, val verbosities: List<Choice>,
        val proactive: String, val proactives: List<Choice>, val emoji: Boolean, val autoSummarize: Boolean,
        val autoSummarizeDetail: String,
        val accessMode: String, val accessModes: List<Choice>, val purposes: List<Purpose>,
    )

    fun settings(): CoachSettings? = call("coach.settings", "{}")?.let(::parseSettings)

    /** Changes one setting (`persona`, `verbosity`, `proactive`, `emoji`, `autoSummarize`, `accessMode`, or a purpose). */
    fun updateSettings(args: JSONObject): CoachSettings? = call("coach.settings.set", args.toString())?.let(::parseSettings)

    internal fun parseSettings(o: JSONObject): CoachSettings? {
        if (!o.has("persona")) return null
        fun choices(k: String) = o.optJSONArray(k).let { a ->
            (0 until (a?.length() ?: 0)).map { a!!.getJSONObject(it).let { c -> Choice(c.getString("id"), c.getString("label"), c.optString("detail")) } }
        }
        val p = o.optJSONArray("purposes")
        return CoachSettings(
            o.getString("persona"), choices("personas"), o.getString("verbosity"), choices("verbosities"),
            o.getString("proactive"), choices("proactives"), o.optBoolean("emoji"), o.optBoolean("autoSummarize"),
            o.optString("autoSummarizeDetail"),
            o.getString("accessMode"), choices("accessModes"),
            (0 until (p?.length() ?: 0)).map { p!!.getJSONObject(it).let { c ->
                Purpose(c.getString("id"), c.getString("label"), c.optString("detail"), c.optBoolean("on")) } },
        )
    }

    /** One saved thread in the history (`CoachHistoryView`). */
    data class Conversation(
        val id: String, val title: String, val preview: String, val updatedAt: Long, val pinned: Boolean,
        val archived: Boolean, val active: Boolean, val searchText: String,
    )

    fun conversations(): List<Conversation>? = call("coach.conversations", "{}")?.let(::parseConversations)

    /** Switches to, renames, deletes, archives or pins a thread; returns the history afterwards. */
    fun conversationOp(op: String, id: String, title: String? = null, value: Boolean? = null): List<Conversation>? {
        val args = JSONObject().put("id", id)
        title?.let { args.put("title", it) }
        value?.let { args.put("value", it) }
        return call("coach.$op", args.toString())?.let(::parseConversations)
    }

    internal fun parseConversations(o: JSONObject): List<Conversation>? {
        val list = o.optJSONArray("conversations") ?: return null
        return (0 until list.length()).map { i ->
            val c = list.getJSONObject(i)
            Conversation(c.getString("id"), c.getString("title"), c.optString("preview"),
                         (c.optDouble("updatedAt") * 1000).toLong(), c.optBoolean("pinned"), c.optBoolean("archived"),
                         c.optBoolean("active"), c.optString("searchText"))
        }
    }

    /** The coach's plan book (`CoachPlanView`), every line worded by the core. */
    data class Plan(
        val pending: List<PlanRow>, val agreed: List<PlanRow>, val recent: List<PlanRow>, val empty: Boolean,
        val skipReasons: List<Pair<String, String>>, val feedbacks: List<Pair<String, String>>,
        val intents: List<Pair<String, String>> = emptyList(),
    )
    data class PlanRow(
        val id: String, val summary: String, val rationale: String, val day: String, val dayLabel: String,
        val status: String, val swappedFrom: String?, val statusLine: String, val feedback: String?, val feedbackLabel: String?,
        val sport: String = "", val intent: String = "", val time: Long? = null,
    )

    /** Reads the plan, or applies [op] (`accept`, `decline`, `complete`, `skip`, `feedback`) to one proposal first. */
    fun plan(effortScale: String, op: String? = null, id: String? = null, reason: String? = null, feedback: String? = null,
             time: Long? = null, day: String? = null, sport: String? = null, intent: String? = null): Plan? {
        val args = JSONObject().put("effortScale", effortScale)
        time?.let { args.put("time", it) }
        day?.let { args.put("day", it) }
        sport?.let { args.put("sport", it) }
        intent?.let { args.put("intent", it) }
        id?.let { args.put("id", it) }
        reason?.let { args.put("reason", it) }
        feedback?.let { args.put("feedback", it) }
        return call(if (op == null) "coach.plan" else "coach.plan.$op", args.toString())?.let(::parsePlan)
    }

    internal fun parsePlan(o: JSONObject): Plan? {
        if (!o.has("pending")) return null
        fun rows(key: String) = o.optJSONArray(key).let { a ->
            (0 until (a?.length() ?: 0)).map { i ->
                val r = a!!.getJSONObject(i)
                fun opt(k: String) = if (r.isNull(k)) null else r.optString(k).takeIf { it.isNotEmpty() }
                PlanRow(r.getString("id"), r.getString("summary"), r.optString("rationale"), r.getString("day"),
                        r.optString("dayLabel"), r.getString("status"), opt("swappedFrom"), r.optString("statusLine"),
                        opt("feedback"), opt("feedbackLabel"), r.optString("sport"), r.optString("intent"),
                        if (r.isNull("time") || !r.has("time")) null else r.getDouble("time").toLong())
            }
        }
        fun choices(key: String) = o.optJSONArray(key).let { a ->
            (0 until (a?.length() ?: 0)).map { i -> a!!.getJSONObject(i).let { it.getString("id") to it.getString("label") } }
        }
        return Plan(rows("pending"), rows("agreed"), rows("recent"), o.optBoolean("empty"),
                    choices("skipReasons"), choices("feedbacks"), choices("intents"))
    }

    /** The Swift `AIProvider` raw value for a Kotlin provider. */
    internal fun providerId(provider: AiProvider): String = when (provider) {
        AiProvider.OPENAI -> "openAI"
        AiProvider.ANTHROPIC -> "anthropic"
        AiProvider.GEMINI -> "gemini"
        AiProvider.CUSTOM -> "custom"
    }

    internal fun parse(o: JSONObject): State? {
        if (o.has("error") && !o.has("messages")) return null
        val list = o.optJSONArray("messages")
        val messages = (0 until (list?.length() ?: 0)).map { i ->
            val m = list!!.getJSONObject(i)
            ChatMsg(id = m.getString("id"), role = m.getString("role"), text = m.getString("text"))
        }
        val error = if (o.isNull("error")) null else o.optString("error").takeIf { it.isNotEmpty() }
        return State(messages, o.optBoolean("sending"), error, o.optBoolean("configured"), o.optString("name"))
    }

    private fun call(op: String, args: String): JSONObject? {
        if (!SwiftCore.available) return null
        return SwiftCore.call(op, args)?.let { runCatching { JSONObject(it) }.getOrNull() }
    }
}
