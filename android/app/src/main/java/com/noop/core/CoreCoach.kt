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
    data class State(val messages: List<ChatMsg>, val sending: Boolean, val error: String?, val configured: Boolean)

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
        return State(messages, o.optBoolean("sending"), error, o.optBoolean("configured"))
    }

    private fun call(op: String, args: String): JSONObject? {
        if (!SwiftCore.available) return null
        return SwiftCore.call(op, args)?.let { runCatching { JSONObject(it) }.getOrNull() }
    }
}
