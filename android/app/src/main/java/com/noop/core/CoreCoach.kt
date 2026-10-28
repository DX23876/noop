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
                     val name: String = "", val recovery: String? = null, val retryAfter: Int? = null,
                     val canDeepen: Boolean = false)

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

    fun regenerate(): State? = call("coach.regenerate", "{}")?.let(::parse)

    /** Asks the deep-analysis model to look at the last answer again. */
    fun deeper(): State? = call("coach.deeper", "{}")?.let(::parse)

    /** "Edit and ask again": the last question, with its exchange removed from the chat. */
    fun reclaim(): Pair<String?, State?> = call("coach.reclaim", "{}")?.let { o ->
        (if (o.isNull("question")) null else o.optString("question")) to o.optJSONObject("state")?.let(::parse)
    } ?: (null to null)

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

    /** The coach's memory (`CoachMemory`): facts with category, origin and expiry, and the categories. */
    data class Fact(val id: String, val text: String, val category: String, val categoryLabel: String, val source: String,
                    val active: Boolean, val expires: Double?, val sensitive: Boolean)
    data class Memory(val facts: List<Fact>, val categories: List<Choice>)

    /** Reads the memory, or first applies [op] (`add`, `update`, `remove`, `expire`, `unexpire`, `clear`). */
    fun memory(op: String? = null, id: String? = null, text: String? = null, category: String? = null): Memory? {
        val args = JSONObject()
        id?.let { args.put("id", it) }; text?.let { args.put("text", it) }; category?.let { args.put("category", it) }
        val o = call(if (op == null) "coach.memory" else "coach.memory.$op", args.toString()) ?: return null
        val f = o.optJSONArray("facts") ?: return null
        val c = o.optJSONArray("categories")
        return Memory(
            (0 until f.length()).map { i -> f.getJSONObject(i).let { x ->
                Fact(x.getString("id"), x.getString("text"), x.optString("category"), x.optString("categoryLabel"),
                     x.optString("source"), x.optBoolean("active", true),
                     if (x.isNull("expires") || !x.has("expires")) null else x.getDouble("expires"), x.optBoolean("sensitive")) } },
            (0 until (c?.length() ?: 0)).map { i -> c!!.getJSONObject(i).let { Choice(it.getString("id"), it.getString("label"), "") } },
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
        fun opt(x: JSONObject, k: String) = if (!x.has(k) || x.isNull(k)) null else x.optString(k).takeIf { it.isNotEmpty() }
        val messages = (0 until (list?.length() ?: 0)).map { i ->
            val m = list!!.getJSONObject(i)
            val ev = m.optJSONArray("evidence")
            val chart = m.optJSONObject("chart")?.let { c ->
                val pts = c.optJSONArray("points")
                ChatMsg.Chart(c.getString("title"), c.optString("kind"),
                    (0 until (pts?.length() ?: 0)).map { pts!!.getJSONObject(it).let { p -> p.getDouble("date") to p.getDouble("value") } },
                    c.optDouble("lo"), c.optDouble("hi"))
            }
            val card = m.optJSONObject("card")?.let { c ->
                val rows = c.optJSONArray("rows")
                ChatMsg.Card(c.optString("kind"), c.getString("title"), c.optString("value"), opt(c, "caption"),
                    (0 until (rows?.length() ?: 0)).map { rows!!.getJSONObject(it).let { r -> r.getString("label") to r.getString("value") } },
                    c.optString("tint"))
            }
            ChatMsg(id = m.getString("id"), role = m.getString("role"), text = m.getString("text"),
                    date = m.optDouble("date", 0.0), gotInTouch = opt(m, "gotInTouch"), evidenceHeader = opt(m, "evidenceHeader"),
                    evidence = (0 until (ev?.length() ?: 0)).map { ev!!.getString(it) }, chart = chart, card = card)
        }
        val error = if (o.isNull("error")) null else o.optString("error").takeIf { it.isNotEmpty() }
        return State(messages, o.optBoolean("sending"), error, o.optBoolean("configured"), o.optString("name"),
                     opt(o, "recovery"), if (o.has("retryAfter") && !o.isNull("retryAfter")) o.optInt("retryAfter") else null,
                     o.optBoolean("canDeepen"))
    }

    private fun call(op: String, args: String): JSONObject? {
        if (!SwiftCore.available) return null
        return SwiftCore.call(op, args)?.let { runCatching { JSONObject(it) }.getOrNull() }
    }
}
