package com.noop.ui.forge

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.height
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import java.io.ByteArrayOutputStream
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.SwiftCore
import com.noop.ui.LogExport
import com.noop.ui.MASTER_REPORT_MODE
import com.noop.ui.buildPending
import com.noop.ui.AppViewModel
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.ChevronRight
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * Reporting a problem from inside the app, and following what became of it. The Apple twin is
 * `ProjectReportViews.swift`, and both are thin: every rule lives in the core behind `project.report`,
 * `project.thread`, `project.reply` and `project.withdraw`, so the two platforms cannot drift on what
 * a code is, what a status means, or when something counts as new.
 *
 * The order is the promise, the same on both: write, see the log you are about to attach, send, get
 * the code, follow the thread. The log step is the review gate the Test Centre has always used; a log
 * carries device details and sometimes more, so the only honest way to send one is to show it first.
 */

/** One remembered report, as the core hands it over. */
internal data class MyReport(val code: String, val title: String, val status: String)

private fun parseReports(json: String?): List<MyReport> {
    val array = runCatching { JSONObject(json ?: "").optJSONArray("reports") }.getOrNull()
        ?: JSONArray()
    return (0 until array.length()).mapNotNull { index ->
        val row = array.optJSONObject(index) ?: return@mapNotNull null
        val code = row.optString("code")
        if (code.isEmpty()) null
        else MyReport(code, row.optString("title"), row.optString("seenStatus", "arrived"))
    }
}

@Composable
internal fun statusText(status: String): String = stringResource(
    when (status) {
        "read" -> R.string.project_report_status_read
        "working" -> R.string.project_report_status_working
        "fixed" -> R.string.project_report_status_fixed
        "notPlanned" -> R.string.project_report_status_not_planned
        else -> R.string.project_report_status_arrived
    }
)

/**
 * The way in and what this device has reported. First on the Problems page: somebody who opens it
 * because something is broken should not have to read everyone else's problems to find out where to
 * say so.
 */
@Composable
internal fun ProjectReportSection(canWrite: Boolean, viewModel: AppViewModel) {
    if (!canWrite) return
    var mine by remember { mutableStateOf(emptyList<MyReport>()) }
    var composing by remember { mutableStateOf(false) }
    var openCode by remember { mutableStateOf<String?>(null) }
    var typing by remember { mutableStateOf(false) }
    var typed by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    suspend fun reload() {
        mine = parseReports(withContext(Dispatchers.IO) { SwiftCore.call("project.reports", "{}") })
    }
    LaunchedEffect(composing, openCode) { reload() }

    val code = openCode
    when {
        code != null -> ThreadScreen(code, mine.firstOrNull { it.code == code }?.status,
                                     onBack = { openCode = null },
                                     onGone = { openCode = null; scope.launch { reload() } })
        composing -> ReportForm(viewModel, onDone = { composing = false })
        else -> {
            SectionHeader(stringResource(R.string.project_report_broken))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                HubRow(androidx.compose.material.icons.Icons.Rounded.BugReport,
                       ForgeTokens.Color.systemTeal.resolve(),
                       stringResource(R.string.project_report_open),
                       stringResource(R.string.project_report_open_detail)) { composing = true }
            }

            SectionHeader(stringResource(R.string.project_report_mine))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                if (mine.isEmpty()) {
                    Text(stringResource(R.string.project_report_mine_note),
                         style = Forge.type.caption, color = Forge.colors.textSecondary)
                } else {
                    mine.forEach { report ->
                        // The chevron every other row here has. Without it this one was the only
                        // thing on the page that opened something and did not say so.
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                                .clickable(role = Role.Button) { openCode = report.code },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f),
                                   verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(report.title, style = Forge.type.body, color = Forge.colors.text)
                                Text(statusText(report.status), style = Forge.type.caption,
                                     color = Forge.colors.textTertiary)
                            }
                            Icon(Icons.Rounded.ChevronRight, contentDescription = null,
                                 tint = Forge.colors.textTertiary, modifier = Modifier.size(18.dp))
                        }
                    }
                }
                Row(
                    Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                        .clickable(role = Role.Button) { typing = true },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.project_report_have_code),
                         style = Forge.type.body, color = Forge.colors.accent)
                }
            }
        }
    }

    if (typing) {
        // Whether this is a code at all is the core's answer, not a second copy of the alphabet
        // here. Nothing else is verified: the thread screen asks the service, and a code that means
        // nothing answers exactly like one that was withdrawn.
        var looksLikeACode by remember { mutableStateOf(false) }
        LaunchedEffect(typed) {
            looksLikeACode = runCatching {
                JSONObject(withContext(Dispatchers.IO) {
                    SwiftCore.call("project.codeOk", JSONObject().put("code", typed.trim()).toString())
                } ?: "").optBoolean("ok")
            }.getOrDefault(false)
        }
        AlertDialog(
            onDismissRequest = { typing = false; typed = "" },
            title = { Text(stringResource(R.string.project_report_have_code)) },
            text = {
                OutlinedTextField(value = typed, onValueChange = { typed = it.uppercase() },
                                  placeholder = { Text(stringResource(R.string.project_report_code_example)) })
            },
            confirmButton = {
                TextButton(enabled = looksLikeACode, onClick = {
                    openCode = typed.trim()
                    typing = false
                    typed = ""
                }) { Text(stringResource(R.string.forge_roadmap_send)) }
            },
        )
    }
}

/**
 * The ONE sentence for each reason a write did not go out, the twin of `ProjectReportWording` on
 * Apple. The reason itself is decided once, in the shared core (`ProjectService.failure`); this maps
 * it to words, so the form and the thread cannot word the same cause differently.
 *
 * An unknown name answers like silence rather than inventing a fifth meaning: a core that learns a
 * new reason before this screen does must not print something that did not happen.
 */
internal object ProjectReportWording {
    fun sentence(why: String): Int = when (why) {
        "notSending" -> R.string.project_report_failed_not_sending
        "tooMany" -> R.string.project_report_failed_too_many
        "refused" -> R.string.project_report_failed_refused
        else -> R.string.project_report_failed_unreachable
    }
}

/** What happened, whether questions may come back, and whether the log rides along. */
@Composable
private fun ReportForm(viewModel: AppViewModel, onDone: () -> Unit) {
    val context = LocalContext.current
    var draft by remember { mutableStateOf("") }
    var wantsThread by remember { mutableStateOf(true) }
    var attachLog by remember { mutableStateOf(true) }
    var sending by remember { mutableStateOf(false) }
    // Building the log reads the strap archive and probes the store, which takes seconds. Without a
    // state of its own the button said "Send" throughout, so a second tap built a second bundle and
    // opened a second sheet over the first. The Apple twin calls this `isPreparing`.
    var preparing by remember { mutableStateOf(false) }
    // Not a Bool: the core names WHICH of the four reasons it was, and one sentence for all of them
    // is what left a tester with nothing to act on. The Apple twin calls this `failure`.
    var failure by remember { mutableStateOf<String?>(null) }
    var code by remember { mutableStateOf<String?>(null) }
    var sentWithoutThread by remember { mutableStateOf(false) }
    var staged by remember { mutableStateOf<com.noop.ui.PendingReport?>(null) }
    var picture by remember { mutableStateOf<ByteArray?>(null) }
    // Read here, not trusted from the page: the switch that decides it sits on the same screen as
    // the way in, so it can be thrown after this row was drawn. The Apple twin calls this `canWrite`.
    var sharingOn by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        sharingOn = runCatching {
            JSONObject(withContext(Dispatchers.IO) { SwiftCore.call("project.sharing", "{}") } ?: "")
                .optBoolean("on", true)
        }.getOrDefault(true)
    }
    val pick = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            picture = withContext(Dispatchers.IO) { ReportPicture.scaled(context, uri) }
        }
    }

    suspend fun send(log: ByteArray?) {
        sending = true
        failure = null
        val answer = withContext(Dispatchers.IO) {
            SwiftCore.call("project.report", JSONObject().put("text", draft)
                .put("thread", wantsThread).toString())
        }
        val root = runCatching { JSONObject(answer ?: "") }.getOrNull()
        if (root?.optBoolean("ok") == true) {
            val handed = root.optString("code").takeIf { it.isNotEmpty() }
            if (handed != null) {
                // The log goes second: without a code there is nowhere to put it, and a report that
                // arrived without its log is still a report.
                if (log != null) {
                    withContext(Dispatchers.IO) {
                        SwiftCore.call("project.reportLog", JSONObject().put("code", handed)
                            .put("data", Base64.encodeToString(log, Base64.NO_WRAP)).toString())
                    }
                }
                code = handed
            } else {
                sentWithoutThread = true
            }
        } else {
            failure = root?.optString("why")?.takeIf { it.isNotEmpty() } ?: "unreachable"
        }
        sending = false
    }

    val handed = code
    if (handed != null) {
        SectionHeader(stringResource(R.string.project_report_sent))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Text(stringResource(R.string.project_report_keep_code), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
            Text(handed, style = Forge.type.title2, color = Forge.colors.text)
            Row(
                Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                    .clickable(role = Role.Button) { onDone() },
                verticalAlignment = Alignment.CenterVertically,
            ) { Text(stringResource(R.string.forge_roadmap_show_less), style = Forge.type.body,
                     color = Forge.colors.accent) }
        }
        return
    }
    if (sentWithoutThread) {
        SectionHeader(stringResource(R.string.project_report_sent))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Text(stringResource(R.string.project_report_no_thread_sent), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
        }
        return
    }

    if (!sharingOn) {
        // Named as the switch it is, and pointing at where that switch lives, rather than offering a
        // Send that cannot send.
        SectionHeader(stringResource(R.string.project_report_switched_off_title))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Text(stringResource(R.string.project_report_switched_off_body), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
        }
        return
    }

    SectionHeader(stringResource(R.string.project_report_what))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        OutlinedTextField(
            value = draft, onValueChange = { if (it.length <= MAX_REPORT) draft = it },
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(stringResource(R.string.project_report_hint)) },
            textStyle = Forge.type.body, maxLines = 8,
        )
        Text(stringResource(R.string.forge_roadmap_chars_left, MAX_REPORT - draft.length),
             style = Forge.type.caption, color = Forge.colors.textTertiary)
    }

    // A log and a picture are both filed under the code, and without questions back there is no
    // code. So neither is offered then, rather than being taken and dropped at the end.
    if (wantsThread) {
        SectionHeader(stringResource(R.string.project_report_picture))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            val shot = picture
            if (shot != null) {
                val bitmap = remember(shot) { BitmapFactory.decodeByteArray(shot, 0, shot.size) }
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap.asImageBitmap(), contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxWidth().height(180.dp),
                    )
                }
                Row(
                    Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                        .clickable(role = Role.Button) { picture = null },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.project_report_picture_remove),
                         style = Forge.type.body, color = ForgeTokens.Color.systemRed.resolve())
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                        .clickable(role = Role.Button) {
                            pick.launch(PickVisualMediaRequest(
                                ActivityResultContracts.PickVisualMedia.ImageOnly))
                        },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(stringResource(R.string.project_report_picture_add),
                             style = Forge.type.body, color = Forge.colors.accent)
                        Text(stringResource(R.string.project_report_picture_detail),
                             style = Forge.type.caption, color = Forge.colors.textSecondary)
                    }
                }
            }
    }

    }

    SectionHeader(stringResource(R.string.project_report_how))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        ToggleRow(stringResource(R.string.project_report_thread),
                  stringResource(R.string.project_report_thread_detail), wantsThread) {
            wantsThread = it
            attachLog = it
            if (!it) picture = null
        }
        if (wantsThread) {
            ToggleRow(stringResource(R.string.project_report_log),
                      stringResource(R.string.project_report_log_detail), attachLog) { attachLog = it }
        }
    }
    if (!wantsThread) {
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Text(stringResource(R.string.project_report_no_thread_note), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
        }
    }

    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                .clickable(enabled = draft.isNotBlank() && !sending && !preparing,
                           role = Role.Button) {
                    scope.launch {
                        if (!attachLog) {
                            // A picture without a log is still worth sending.
                            val shot = picture
                            send(if (shot == null) null else withContext(Dispatchers.IO) {
                                LogExport.zipEntries(listOf("picture.jpg" to shot))
                            })
                            return@launch
                        }
                        // With a log: build it, show it, and send only on an explicit press.
                        preparing = true
                        staged = runCatching {
                            buildPending(context, MASTER_REPORT_MODE,
                                         viewModel.ble.exportLogText(), viewModel)
                        }.getOrNull()
                        preparing = false
                        // Nothing to show means nothing to attach. The report still goes, rather
                        // than opening an empty sheet over a bundle that is not there.
                        if (staged == null) send(null)
                    }
                },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(when {
                     preparing -> R.string.project_report_preparing
                     sending -> R.string.project_report_sending
                     else -> R.string.project_report_send
                 }),
                 style = Forge.type.body,
                 color = if (draft.isNotBlank() && !sending && !preparing) Forge.colors.accent
                         else Forge.colors.textTertiary)
        }
        val why = failure
        if (why != null) {
            Text(stringResource(ProjectReportWording.sentence(why)), style = Forge.type.caption,
                 color = Forge.colors.textSecondary)
        }
    }

    val pending = staged
    if (pending != null) {
        AlertDialog(
            onDismissRequest = { staged = null },
            title = { Text(stringResource(R.string.project_report_review_title)) },
            text = {
                Text(pending.gate.previewText,
                     style = Forge.type.caption, color = Forge.colors.textSecondary,
                     modifier = Modifier.verticalScroll(rememberScrollState()))
            },
            confirmButton = {
                TextButton(onClick = {
                    staged = null
                    scope.launch {
                        val shot = picture
                        val entries = if (shot == null) pending.entries
                                      else pending.entries + ("picture.jpg" to shot)
                        send(withContext(Dispatchers.IO) { LogExport.zipEntries(entries) })
                    }
                }) { Text(stringResource(R.string.project_report_review_with)) }
            },
            dismissButton = {
                TextButton(onClick = { staged = null; scope.launch { send(null) } }) {
                    Text(stringResource(R.string.project_report_review_without))
                }
            },
        )
    }
}

/** One report: where it stands, what was said, the way to answer, and the way to take it back. */
@Composable
private fun ThreadScreen(code: String, seen: String?, onBack: () -> Unit, onGone: () -> Unit) {
    // The last status this device was told, until the service says otherwise. Starting at "arrived"
    // meant an unreachable service printed "nobody has looked at it yet" over a report that was
    // fixed weeks ago: a line stating what it had not observed.
    var status by remember { mutableStateOf(seen) }
    var fixedIn by remember { mutableStateOf<String?>(null) }
    var publicNumber by remember { mutableStateOf(0) }
    var messages by remember { mutableStateOf(emptyList<Triple<Boolean, String, String>>()) }
    var loaded by remember { mutableStateOf(false) }
    var reached by remember { mutableStateOf(true) }
    // Switched off is not the same as unreachable, and saying "could not be checked" would blame the
    // network for a switch the wearer threw themselves.
    var sharingOn by remember { mutableStateOf(true) }
    var draft by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var replyFailure by remember { mutableStateOf<String?>(null) }
    var withdrawFailed by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    suspend fun reload() {
        val answer = withContext(Dispatchers.IO) {
            SwiftCore.call("project.thread", JSONObject().put("code", code).toString())
        }
        val root = runCatching { JSONObject(answer ?: "") }.getOrNull()
        if (root?.optBoolean("ok") == true) {
            status = root.optString("status", "arrived")
            fixedIn = root.optString("fixedIn").takeIf { it.isNotEmpty() && it != "null" }
            publicNumber = root.optInt("publicNumber", 0)
            val array = root.optJSONArray("messages") ?: JSONArray()
            messages = (0 until array.length()).mapNotNull { index ->
                val row = array.optJSONObject(index) ?: return@mapNotNull null
                Triple(row.optBoolean("mine"), row.optString("text"), row.optString("at"))
            }
            reached = true
        } else {
            reached = false
        }
        loaded = true
    }
    LaunchedEffect(code) {
        sharingOn = runCatching {
            JSONObject(withContext(Dispatchers.IO) { SwiftCore.call("project.sharing", "{}") } ?: "")
                .optBoolean("on", true)
        }.getOrDefault(true)
        reload()
    }

    Row(
        Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
            .clickable(role = Role.Button) { onBack() },
        verticalAlignment = Alignment.CenterVertically,
    ) { Text(stringResource(R.string.forge_roadmap_show_less), style = Forge.type.body,
             color = Forge.colors.accent) }

    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        status?.let {
            Text(statusText(it), style = Forge.type.headline, color = Forge.colors.text)
        }
        if (!loaded) {
            Text(stringResource(R.string.project_report_checking), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        } else if (!sharingOn) {
            Text(stringResource(R.string.project_report_sharing_off), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        } else if (!reached) {
            Text(stringResource(R.string.project_report_unchecked), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        }
        fixedIn?.let {
            Text(stringResource(R.string.project_report_fixed_in, it), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
        }
        if (publicNumber > 0) {
            Text(stringResource(R.string.project_report_public, publicNumber),
                 style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        Text(code, style = Forge.type.caption, color = Forge.colors.textTertiary)
    }

    SectionHeader(stringResource(R.string.project_report_conversation))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        if (messages.isEmpty() && loaded) {
            Text(stringResource(R.string.project_report_nothing_said), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
        }
        messages.forEach { (mine, text, _) ->
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(stringResource(if (mine) R.string.project_report_you
                                    else R.string.project_report_developer),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
                Text(text, style = Forge.type.body, color = Forge.colors.text)
            }
        }
    }

    if (sharingOn) {
        SectionHeader(stringResource(R.string.project_report_answer))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            OutlinedTextField(
                value = draft, onValueChange = { if (it.length <= MAX_REPLY) draft = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text(stringResource(R.string.project_report_answer_hint)) },
                textStyle = Forge.type.body, maxLines = 6,
            )
            Row(
                Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                    .clickable(enabled = draft.isNotBlank() && !sending, role = Role.Button) {
                        scope.launch {
                            sending = true
                            val answer = withContext(Dispatchers.IO) {
                                SwiftCore.call("project.reply", JSONObject().put("code", code)
                                    .put("text", draft).toString())
                            }
                            val root = runCatching { JSONObject(answer ?: "") }.getOrNull()
                            if (root?.optBoolean("ok") == true) {
                                draft = ""
                                replyFailure = null
                                reload()
                            } else {
                                // The text stays in the field: it is the only copy of it.
                                replyFailure = root?.optString("why")?.takeIf { it.isNotEmpty() }
                                    ?: "unreachable"
                            }
                            sending = false
                        }
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(if (sending) R.string.project_report_sending
                                    else R.string.project_report_send),
                     style = Forge.type.body,
                     color = if (draft.isNotBlank() && !sending) Forge.colors.accent
                             else Forge.colors.textTertiary)
            }
            val replyWhy = replyFailure
            if (replyWhy != null) {
                Text(stringResource(ProjectReportWording.sentence(replyWhy)),
                     style = Forge.type.caption, color = Forge.colors.textSecondary)
            }
    }
    }

    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
                .clickable(role = Role.Button) { confirming = true },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(R.string.project_report_withdraw), style = Forge.type.body,
                 color = ForgeTokens.Color.systemRed.resolve())
        }
        if (withdrawFailed) {
            Text(stringResource(R.string.project_report_withdraw_failed), style = Forge.type.caption,
                 color = Forge.colors.textSecondary)
        }
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text(stringResource(R.string.project_report_withdraw)) },
            text = { Text(stringResource(R.string.project_report_withdraw_note)) },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    scope.launch {
                        val answer = withContext(Dispatchers.IO) {
                            SwiftCore.call("project.withdraw", JSONObject().put("code", code).toString())
                        }
                        if (runCatching { JSONObject(answer ?: "") }.getOrNull()
                                ?.optBoolean("ok") == true) onGone() else withdrawFailed = true
                    }
                }) { Text(stringResource(R.string.project_report_withdraw)) }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }) {
                    Text(stringResource(R.string.project_report_review_without))
                }
            },
        )
    }
}

private const val MAX_REPORT = 2000
private const val MAX_REPLY = 1000
