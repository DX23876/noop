package com.noop.ui.forge

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.SwiftCore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

//* "Help teach the app", the Android twin of iOS `RawDonationView`.
//*
//* Every decision is the core's: which sports are ticked, how the windows are laid out, what the package
//* carries and where it goes. Kotlin draws the page and presses the buttons. Nothing records until a
//* sport is ticked, nothing is sent until someone presses send, and without a service address in the feed
//* the send does not exist at all.

internal data class DonationRow(
    val id: String, val code: String, val sport: String, val seconds: Int, val bytes: Int,
    val sent: Boolean,
)

/** The sports a strap-worn recording is useful for. Strength is left out, as on iOS. */
internal val DONATION_SPORTS = listOf("Walking", "Running", "Cycling", "Hiking", "Rowing")

private fun parseRows(json: String?): List<DonationRow> {
    val array = runCatching { JSONArray(json ?: "[]") }.getOrNull() ?: return emptyList()
    return (0 until array.length()).mapNotNull { index ->
        val row = array.optJSONObject(index) ?: return@mapNotNull null
        DonationRow(row.optString("id"), row.optString("code"), row.optString("sport"),
                    row.optInt("recordedSeconds"), row.optInt("bytes"), !row.isNull("sentAt"))
    }
}

@Composable
internal fun RawDonationSection() {
    val scope = rememberCoroutineScope()
    var ticked by remember { mutableStateOf(emptySet<String>()) }
    var keepCopy by remember { mutableStateOf(false) }
    var rows by remember { mutableStateOf(emptyList<DonationRow>()) }
    var canSend by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf<String?>(null) }
    var failed by remember { mutableStateOf<String?>(null) }

    suspend fun reload() {
        val settings = withContext(Dispatchers.IO) { SwiftCore.call("donation.settings", "{}") }
        val root = runCatching { JSONObject(settings ?: "{}") }.getOrNull()
        val sports = root?.optJSONArray("sports")
        ticked = (0 until (sports?.length() ?: 0)).mapNotNull { sports?.optString(it) }.toSet()
        keepCopy = root?.optBoolean("keepCopy") == true
        rows = parseRows(withContext(Dispatchers.IO) { SwiftCore.call("donation.pending", "{}") })
        val page = withContext(Dispatchers.IO) { SwiftCore.call("project.cached", "{}") }
        canSend = runCatching { JSONObject(page ?: "{}") }.getOrNull()?.isNull("service") == false
    }

    LaunchedEffect(Unit) { reload() }

    SectionHeader(stringResource(R.string.donation_what_title))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Text(stringResource(R.string.donation_what), style = Forge.type.body,
             color = Forge.colors.textSecondary)
        Text(stringResource(R.string.donation_not_in_it), style = Forge.type.caption,
             color = Forge.colors.textSecondary)
        Text(stringResource(R.string.donation_no_link), style = Forge.type.caption,
             color = Forge.colors.textTertiary)
        Text(stringResource(R.string.donation_what_for), style = Forge.type.body,
             color = Forge.colors.textSecondary)
        Text(stringResource(R.string.donation_promise), style = Forge.type.caption,
             color = Forge.colors.textTertiary)
    }

    SectionHeader(stringResource(R.string.donation_sports_title))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        DONATION_SPORTS.forEach { sport ->
            val key = sport.lowercase()
            Row(Modifier.fillMaxWidth().heightIn(min = 44.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(sport, style = Forge.type.body, color = Forge.colors.text,
                     modifier = Modifier.weight(1f))
                Switch(checked = ticked.contains(key), onCheckedChange = { on ->
                    scope.launch {
                        withContext(Dispatchers.IO) {
                            SwiftCore.call("donation.setSport",
                                           JSONObject().put("sport", sport).put("on", on).toString())
                        }
                        reload()
                    }
                })
            }
        }
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.donation_keep_copy), style = Forge.type.body,
                 color = Forge.colors.text, modifier = Modifier.weight(1f))
            Switch(checked = keepCopy, onCheckedChange = { on ->
                scope.launch {
                    withContext(Dispatchers.IO) {
                        SwiftCore.call("donation.keepCopy", JSONObject().put("on", on).toString())
                    }
                    reload()
                }
            })
        }
    }
    Text(stringResource(R.string.donation_sports_note), style = Forge.type.caption,
         color = Forge.colors.textSecondary, modifier = Modifier.padding(horizontal = ForgeMetrics.space2))

    SectionHeader(stringResource(R.string.donation_yours_title))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        if (rows.isEmpty()) {
            Text(stringResource(R.string.donation_none), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
        } else {
            rows.forEach { row ->
                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    val label = row.code + " \u00b7 " + row.sport
                    Text(label, style = Forge.type.body, color = Forge.colors.text)
                    Text(stringResource(R.string.donation_summary,
                                        maxOf(1, row.seconds / 60), maxOf(1, row.bytes / 1000)),
                         style = Forge.type.caption, color = Forge.colors.textTertiary)
                    Row(verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                        when {
                            row.sent -> Text(stringResource(R.string.donation_sent),
                                             style = Forge.type.caption, color = Forge.colors.accent)
                            canSend -> TextButton(
                                enabled = sending == null,
                                onClick = {
                                    scope.launch {
                                        sending = row.id
                                        failed = null
                                        val ok = withContext(Dispatchers.IO) {
                                            // Kotlin holds the bytes only to hand them over; the core
                                            // decides where they go, as with every other write.
                                            val payload = RawDonationCapture.payloadBase64(row.id)
                                            val answer = SwiftCore.call(
                                                "donation.send",
                                                JSONObject().put("id", row.id)
                                                    .put("payload", payload)
                                                    .put("appVersion", com.noop.BuildConfig.VERSION_NAME)
                                                    .toString())
                                            runCatching { JSONObject(answer ?: "") }.getOrNull()
                                                ?.optBoolean("ok") == true
                                        }
                                        sending = null
                                        if (!ok) failed = row.id
                                        reload()
                                    }
                                },
                            ) {
                                Text(stringResource(R.string.donation_send), color = Forge.colors.accent)
                            }
                        }
                        TextButton(onClick = {
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    SwiftCore.call("donation.forget",
                                                   JSONObject().put("id", row.id).toString())
                                }
                                reload()
                            }
                        }) {
                            Text(stringResource(R.string.donation_delete),
                                 color = Forge.colors.textSecondary)
                        }
                        Spacer(Modifier.weight(1f))
                    }
                    if (failed == row.id) {
                        Text(stringResource(R.string.forge_roadmap_send_failed),
                             style = Forge.type.caption, color = Forge.colors.textSecondary)
                    }
                }
            }
        }
    }
    if (!canSend && rows.isNotEmpty()) {
        Text(stringResource(R.string.donation_no_service), style = Forge.type.caption,
             color = Forge.colors.textSecondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space2))
    }

    Text(stringResource(R.string.donation_caveat), style = Forge.type.caption,
         color = ForgeTokens.Color.systemOrange.resolve(),
         modifier = Modifier.padding(horizontal = ForgeMetrics.space2))
}

/** Where the recorded bytes come from. Filled by the recorder; empty until something was recorded. */
internal object RawDonationCapture {
    @Volatile var payloadProvider: ((String) -> ByteArray)? = null

    fun payloadBase64(id: String): String {
        val bytes = payloadProvider?.invoke(id) ?: ByteArray(0)
        return android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
    }
}
