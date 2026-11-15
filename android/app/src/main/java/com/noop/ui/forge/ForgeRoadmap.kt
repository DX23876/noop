package com.noop.ui.forge

import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AccessTime
import androidx.compose.material.icons.rounded.ArrowForward
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.Build
import androidx.compose.material.icons.rounded.Dashboard
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.InsertChart
import androidx.compose.material.icons.rounded.Map
import androidx.compose.material.icons.rounded.NightsStay
import androidx.compose.material.icons.rounded.OpenInNew
import androidx.compose.material.icons.rounded.PhoneIphone
import androidx.compose.material.icons.rounded.ThumbUp
import androidx.compose.material.icons.rounded.Timeline
import androidx.compose.material.icons.rounded.Whatshot
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.SwiftCore
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The Roadmap page, the Android twin of iOS `RoadmapView`.
 *
 * Nothing is read, clamped, grouped or decided here: the core's `ProjectPageStore` does all of it behind the
 * `project.page` operation, so the two platforms cannot drift on what a status word means, which items a file
 * from a later generator loses, or how a title is shortened. Kotlin draws what it is handed.
 *
 * Two static files from the repository are read when this page opens, and at no other time. No account, no
 * poll, nothing about the reader sent. Quiet by design: no badge on the Settings row, no notification, no
 * ranking of reported problems.
 */

/** One planned piece of work, as the owner wrote it in `docs/roadmap.json`. */
internal data class RoadmapItem(
    val id: String, val phase: String, val title: String, val line: String,
    val icon: String, val area: String, val since: String?,
)

/** One reported problem: number, title, state. The feed carries no body and no author, by design. */
internal data class RoadmapIssue(
    val number: Int, val title: String, val status: String,
    val opened: String?, val closed: String?, val fixedIn: String?,
)

/** One suggestion somebody sent in, with the owner's answer. */
internal data class RoadmapSuggestion(
    val id: String, val title: String, val detail: String, val status: String,
    val reply: String?, val roadmapId: String?,
)

/** The whole page as the core hands it over. */
internal data class RoadmapPage(
    val roadmap: List<RoadmapItem> = emptyList(),
    val suggestions: List<RoadmapSuggestion> = emptyList(),
    val canWrite: Boolean = false,
    val voted: Set<String> = emptySet(),
    val reported: List<RoadmapIssue> = emptyList(),
    val fixed: List<RoadmapIssue> = emptyList(),
    val decided: List<RoadmapIssue> = emptyList(),
    val reportedCount: Int = 0,
    val workingCount: Int = 0,
    val fetchedAt: String? = null,
) {
    val isEmpty: Boolean
        get() = roadmap.isEmpty() && suggestions.isEmpty() && reported.isEmpty() &&
            fixed.isEmpty() && decided.isEmpty()

    fun items(phase: String): List<RoadmapItem> = roadmap.filter { it.phase == phase }
}

/**
 * The SF Symbol names the roadmap file may use, mapped to Compose icons.
 *
 * `Tools/check_roadmap.py` reads this map and fails when the file uses a name that is missing here, because
 * the alternative is a card that silently draws nothing on Android while it looks right on the iPhone. Add the
 * name here first, then use it in the file.
 */
internal val ROADMAP_ICONS: Map<String, ImageVector> = mapOf(
    "square.grid.2x2.fill" to Icons.Rounded.Dashboard,
    "iphone" to Icons.Rounded.PhoneIphone,
    "figure.run" to Icons.Rounded.DirectionsRun,
    "sparkles" to Icons.Rounded.AutoAwesome,
    "flame.fill" to Icons.Rounded.Whatshot,
    "chart.xyaxis.line" to Icons.Rounded.InsertChart,
    "heart.text.square.fill" to Icons.Rounded.FavoriteBorder,
    "bed.double.fill" to Icons.Rounded.NightsStay,
    "dumbbell.fill" to Icons.Rounded.FitnessCenter,
    "bolt.fill" to Icons.Rounded.Bolt,
    "chart.line.uptrend.xyaxis" to Icons.Rounded.Timeline,
    "hammer.fill" to Icons.Rounded.Build,
    "map" to Icons.Rounded.Map,
)

internal object RoadmapDates {
    private val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }
    private val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US)

    /** `yyyy-MM-dd` in the reader's locale, or null when the file carries no date this app can read. */
    fun dayText(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        val parsed = runCatching { day.parse(raw) }.getOrNull() ?: return null
        return DateFormat.getDateInstance(DateFormat.MEDIUM).format(parsed)
    }

    fun stampText(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        val parsed = runCatching { stamp.parse(raw) }.getOrNull() ?: return null
        return DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(parsed)
    }
}

private fun issues(root: JSONObject, key: String): List<RoadmapIssue> {
    val array = root.optJSONArray(key) ?: return emptyList()
    return (0 until array.length()).mapNotNull { index ->
        val row = array.optJSONObject(index) ?: return@mapNotNull null
        val number = row.optInt("n", 0)
        val title = row.optString("title", "")
        if (number <= 0 || title.isEmpty()) return@mapNotNull null
        RoadmapIssue(number, title, row.optString("status", "reported"),
                     row.optStringOrNull("opened"), row.optStringOrNull("closed"),
                     row.optStringOrNull("fixedIn"))
    }
}

private fun JSONObject.optStringOrNull(key: String): String? =
    if (isNull(key)) null else optString(key, "").ifEmpty { null }

/** The core's answer, parsed. Anything unreadable is an empty page, never a crash. */
internal fun parseRoadmapPage(json: String?): RoadmapPage {
    val root = runCatching { JSONObject(json ?: "") }.getOrNull() ?: return RoadmapPage()
    val array = root.optJSONArray("roadmap")
    val items = (0 until (array?.length() ?: 0)).mapNotNull { index ->
        val row = array?.optJSONObject(index) ?: return@mapNotNull null
        val id = row.optString("id", "")
        if (id.isEmpty()) return@mapNotNull null
        RoadmapItem(id, row.optString("phase", ""), row.optString("title", ""),
                    row.optString("line", ""), row.optString("icon", ""),
                    row.optString("area", "app"), row.optStringOrNull("since"))
    }
    val suggestionArray = root.optJSONArray("suggestions")
    val suggestions = (0 until (suggestionArray?.length() ?: 0)).mapNotNull { index ->
        val row = suggestionArray?.optJSONObject(index) ?: return@mapNotNull null
        val id = row.optString("id", "")
        val title = row.optString("title", "")
        if (id.isEmpty() || title.isEmpty()) return@mapNotNull null
        RoadmapSuggestion(id, title, row.optString("detail", ""), row.optString("status", "open"),
                          row.optStringOrNull("reply"), row.optStringOrNull("roadmap"))
    }
    val votedArray = root.optJSONArray("voted")
    return RoadmapPage(
        roadmap = items,
        suggestions = suggestions,
        canWrite = root.optStringOrNull("service") != null,
        voted = (0 until (votedArray?.length() ?: 0)).mapNotNull { votedArray?.optString(it) }.toSet(),
        reported = issues(root, "reported"),
        fixed = issues(root, "fixed"),
        decided = issues(root, "decided"),
        reportedCount = root.optInt("reportedCount", 0),
        workingCount = root.optInt("workingCount", 0),
        fetchedAt = root.optStringOrNull("fetchedAt"),
    )
}

@Composable
private fun areaTint(area: String): Color = when (area) {
    "sleep" -> Forge.colors.rest
    "cardio" -> ForgeTokens.Color.systemPink.resolve()
    "strength" -> ForgeTokens.Color.systemOrange.resolve()
    "body" -> ForgeTokens.Color.systemCyan.resolve()
    else -> Forge.colors.accent
}

private fun statusRes(status: String): Int = when (status) {
    "working" -> R.string.forge_roadmap_status_working
    "fixed" -> R.string.forge_roadmap_status_fixed
    "notPlanned" -> R.string.forge_roadmap_status_not_planned
    else -> R.string.forge_roadmap_status_reported
}

/**
 * The page the four project screens read, loaded once for whichever of them is on screen.
 *
 * They were one screen until 2026-11-15: the plan, a write box and every reported problem in one
 * scroll. Three questions with three rhythms, competing for the same attention, and a wish the reader
 * typed sat below three phases of roadmap. The Apple twin is `ProjectPages.swift`.
 */
@Composable
private fun rememberProjectPage(): Pair<RoadmapPage, Boolean> {
    var page by remember { mutableStateOf(RoadmapPage()) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        page = withContext(Dispatchers.IO) { parseRoadmapPage(SwiftCore.call("project.cached", "{}")) }
        val fresh = withContext(Dispatchers.IO) { parseRoadmapPage(SwiftCore.call("project.page", "{}")) }
        if (!fresh.isEmpty || page.isEmpty) page = fresh
        loaded = true
    }
    return page to loaded
}

/** The picture at the top of a project page, and on its card. A shipped image, dark in both themes. */
@Composable
private fun ProjectScene(drawable: Int, height: Int = 150) {
    Image(
        painter = painterResource(drawable), contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = Modifier.fillMaxWidth().height(height.dp)
            .clip(RoundedCornerShape(ForgeMetrics.groupedRadius)),
    )
}

/** The way in: four cards, each its own page. No badge, no unread dot, no count that reads as alarm. */
@Composable
internal fun ProjectHubSection(
    onRoadmap: () -> Unit,
    onProblems: () -> Unit,
    onWishes: () -> Unit,
    onDonation: () -> Unit,
) {
    val (page, loaded) = rememberProjectPage()
    val planned = page.items("now").size + page.items("next").size + page.items("later").size

    ProjectHubCard(R.drawable.scene_roadmap, stringResource(R.string.forge_roadmap_title),
                   stringResource(R.string.project_card_roadmap_line),
                   if (planned > 0) planned.toString() else null, onRoadmap)
    ProjectHubCard(R.drawable.scene_problems, stringResource(R.string.project_card_problems_title),
                   stringResource(R.string.project_card_problems_line),
                   reportedSummary(page), onProblems)
    ProjectHubCard(R.drawable.scene_wishes, stringResource(R.string.project_card_wishes_title),
                   stringResource(R.string.project_card_wishes_line),
                   if (page.suggestions.isNotEmpty()) page.suggestions.size.toString() else null, onWishes)
    ProjectHubCard(R.drawable.scene_helping, stringResource(R.string.donation_title),
                   stringResource(R.string.donation_subtitle), null, onDonation)

    ProjectSharingCard()
    ProjectStamp(page, loaded)
}

@Composable
private fun ProjectHubCard(drawable: Int, title: String, line: String, status: String?,
                           onOpen: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen),
              radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        ProjectScene(drawable, height = 118)
        Column(Modifier.padding(ForgeMetrics.space3),
               verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.headline, color = Forge.colors.text)
            Text(line, style = Forge.type.body, color = Forge.colors.textSecondary)
            if (status != null) {
                Text(status, style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        }
    }
}

/**
 * The one switch over everything this app sends, read and written through the core so the two
 * platforms cannot drift on what off means. A quiet row at the bottom, not a banner and not a
 * question on first launch.
 */
@Composable
private fun ProjectSharingCard() {
    var on by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        val answer = withContext(Dispatchers.IO) { SwiftCore.call("project.sharing", "{}") }
        on = runCatching { JSONObject(answer ?: "") }.getOrNull()?.optBoolean("on", true) ?: true
    }
    val scope = rememberCoroutineScope()
    SectionHeader(stringResource(R.string.project_sharing_title))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        ToggleRow(stringResource(R.string.project_sharing_row), null, on) { wanted ->
            on = wanted
            scope.launch {
                withContext(Dispatchers.IO) {
                    SwiftCore.call("project.sharing", JSONObject().put("on", wanted).toString())
                }
            }
        }
    }
    Text(stringResource(R.string.project_sharing_note), style = Forge.type.caption,
         color = Forge.colors.textSecondary,
         modifier = Modifier.padding(horizontal = ForgeMetrics.space2))
}

/** "8 reported, 1 being worked on", resolved once so the card and the page cannot differ. */
@Composable
private fun reportedSummary(page: RoadmapPage): String? = when {
    page.reported.isEmpty() -> null
    page.workingCount > 0 ->
        stringResource(R.string.forge_roadmap_summary_working, page.reportedCount, page.workingCount)
    else -> stringResource(R.string.forge_roadmap_summary, page.reportedCount)
}

@Composable
private fun ProjectStamp(page: RoadmapPage, loaded: Boolean) {
    val stamp = RoadmapDates.stampText(page.fetchedAt)
    if (page.isEmpty && loaded) {
        Text(stringResource(R.string.forge_roadmap_empty), style = Forge.type.caption,
             color = Forge.colors.textSecondary)
    } else if (stamp != null) {
        Text(stringResource(R.string.forge_roadmap_checked, stamp), style = Forge.type.caption,
             color = Forge.colors.textTertiary)
    }
}

/** The plan: what is being built now, next, later. Nothing else. */
@Composable
internal fun RoadmapPlanSection() {
    val (page, loaded) = rememberProjectPage()
    ProjectScene(R.drawable.scene_roadmap)
    PhaseSection(R.string.forge_roadmap_now, Icons.Rounded.Build, page.items("now"))
    PhaseSection(R.string.forge_roadmap_next, Icons.Rounded.ArrowForward, page.items("next"))
    PhaseSection(R.string.forge_roadmap_later, Icons.Rounded.AccessTime, page.items("later"))
    if (loaded && page.items("now").isEmpty() && page.items("next").isEmpty() &&
        page.items("later").isEmpty()) {
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Text(stringResource(R.string.project_nothing_listed), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
        }
    }
}

/** What was reported, what is being worked on, what was fixed, what will not be done. */
@Composable
internal fun ProblemsSection(onOpenTestCentre: () -> Unit, onOpenTracker: () -> Unit,
                             viewModel: com.noop.ui.AppViewModel) {
    val (page, _) = rememberProjectPage()
    ProjectScene(R.drawable.scene_problems)
    // First on the page: somebody who opens this because something is broken should not have to read
    // everyone else's problems to find out where to say so.
    ProjectReportSection(page.canWrite, viewModel)

    if (page.reported.isEmpty()) {
        SectionHeader(stringResource(R.string.forge_roadmap_reported))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Text(stringResource(R.string.project_nothing_open), style = Forge.type.body,
                 color = Forge.colors.textSecondary)
        }
    } else {
        var expanded by remember { mutableStateOf(false) }
        SectionHeader(stringResource(R.string.forge_roadmap_reported))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Text(reportedSummary(page) ?: "", style = Forge.type.body,
                 color = Forge.colors.textSecondary)
            Row(
                Modifier.fillMaxWidth().heightIn(min = 44.dp)
                    .clickable(role = Role.Button) { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(if (expanded) R.string.forge_roadmap_show_less else R.string.forge_roadmap_show_all),
                     style = Forge.type.body, color = Forge.colors.accent)
            }
            if (expanded) page.reported.forEach { IssueRow(it) }
        }
    }

    IssueGroup(R.string.forge_roadmap_fixed, page.fixed, null)
    IssueGroup(R.string.forge_roadmap_decided, page.decided, R.string.forge_roadmap_decided_note)

    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
        HubRow(Icons.Rounded.BugReport, ForgeTokens.Color.systemTeal.resolve(),
               stringResource(R.string.forge_roadmap_report),
               stringResource(R.string.forge_roadmap_report_detail), onOpenTestCentre)
        HubDivider()
        HubRow(Icons.Rounded.OpenInNew, ForgeTokens.Color.systemGray.resolve(),
               stringResource(R.string.forge_roadmap_tracker),
               stringResource(R.string.forge_roadmap_tracker_detail), onOpenTracker)
    }
}

/** Ask for something, and back what other people asked for. */
@Composable
internal fun WishesSection() {
    val (initial, _) = rememberProjectPage()
    var page by remember(initial) { mutableStateOf(initial) }
    var counts by remember { mutableStateOf(emptyMap<String, Int>()) }
    var draft by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    // 0 nothing said yet, 1 arrived, 2 did not go out.
    var sentState by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(page.canWrite, page.voted) {
        // Totals only once this device has voted: a number before that steers the vote.
        if (page.canWrite && page.voted.isNotEmpty() && counts.isEmpty()) {
            val answer = withContext(Dispatchers.IO) { SwiftCore.call("project.counts", "{}") }
            val root = runCatching { JSONObject(answer ?: "") }.getOrNull()?.optJSONObject("counts")
            if (root != null) counts = root.keys().asSequence().associateWith { root.optInt(it) }
        }
    }

    ProjectScene(R.drawable.scene_wishes)

    if (page.canWrite) {
        SectionHeader(stringResource(R.string.forge_roadmap_suggest))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            OutlinedTextField(
                value = draft, onValueChange = { if (it.length <= MAX_SUGGESTION) draft = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text(stringResource(R.string.forge_roadmap_suggest_hint)) },
                textStyle = Forge.type.body, maxLines = 4,
            )
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_roadmap_chars_left, MAX_SUGGESTION - draft.length),
                     style = Forge.type.caption, color = Forge.colors.textTertiary,
                     modifier = Modifier.weight(1f))
                TextButton(
                    enabled = draft.isNotBlank() && !sending,
                    onClick = {
                        scope.launch {
                            sending = true
                            val answer = withContext(Dispatchers.IO) {
                                SwiftCore.call("project.suggest",
                                               JSONObject().put("text", draft).toString())
                            }
                            sending = false
                            val ok = runCatching { JSONObject(answer ?: "") }.getOrNull()
                                ?.optBoolean("ok") == true
                            if (ok) draft = ""
                            sentState = if (ok) 1 else 2
                        }
                    },
                ) { Text(stringResource(R.string.forge_roadmap_send), color = Forge.colors.accent) }
            }
            when (sentState) {
                1 -> Text(stringResource(R.string.forge_roadmap_sent), style = Forge.type.caption,
                          color = Forge.colors.textSecondary)
                2 -> Text(stringResource(R.string.forge_roadmap_send_failed), style = Forge.type.caption,
                          color = Forge.colors.textSecondary)
            }
        }
        Text(stringResource(R.string.forge_roadmap_suggest_note), style = Forge.type.caption,
             color = Forge.colors.textSecondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space2))
    }

    if (page.suggestions.isNotEmpty()) {
        SectionHeader(stringResource(R.string.forge_roadmap_suggestions))
        page.suggestions.forEach { suggestion ->
            SuggestionCard(suggestion, page.voted.contains(suggestion.id), counts[suggestion.id],
                           page.canWrite) { wants ->
                scope.launch {
                    val answer = withContext(Dispatchers.IO) {
                        SwiftCore.call("project.vote",
                                       JSONObject().put("id", suggestion.id).put("on", wants).toString())
                    }
                    val root = runCatching { JSONObject(answer ?: "") }.getOrNull()
                    if (root?.optBoolean("ok") == true) {
                        page = page.copy(voted = page.voted.toMutableSet().apply {
                            if (wants) add(suggestion.id) else remove(suggestion.id)
                        })
                        if (root.has("count") && !root.isNull("count")) {
                            counts = counts + (suggestion.id to root.optInt("count"))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SuggestionCard(suggestion: RoadmapSuggestion, voted: Boolean, count: Int?,
                           canVote: Boolean, onVote: (Boolean) -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Text(suggestion.title, style = Forge.type.headline.copy(fontWeight = FontWeight.SemiBold),
             color = Forge.colors.text)
        if (suggestion.detail.isNotEmpty()) {
            Text(suggestion.detail, style = Forge.type.body, color = Forge.colors.textSecondary)
        }
        suggestion.reply?.let {
            Text(it, style = Forge.type.body, color = Forge.colors.text,
                 modifier = Modifier.padding(start = ForgeMetrics.space2))
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            statusRes(suggestion)?.let {
                Text(stringResource(it), style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
            Spacer(Modifier.weight(1f))
            if (canVote) {
                Row(
                    Modifier.heightIn(min = 44.dp).clickable(role = Role.Button) { onVote(!voted) },
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Rounded.ThumbUp,
                         contentDescription = stringResource(
                             if (voted) R.string.forge_roadmap_unvote else R.string.forge_roadmap_vote),
                         tint = if (voted) Forge.colors.accent else Forge.colors.textSecondary,
                         modifier = Modifier.size(20.dp))
                    if (voted && count != null) {
                        Text(count.toString(), style = Forge.type.caption, color = Forge.colors.accent)
                    }
                }
            }
        }
    }
}

/** The one place a suggestion's state becomes a word, so the card and a future list cannot disagree. */
private fun statusRes(suggestion: RoadmapSuggestion): Int? = when {
    suggestion.roadmapId != null -> R.string.forge_roadmap_on_roadmap
    suggestion.status == "planned" -> R.string.forge_roadmap_status_planned
    suggestion.status == "maybe" -> R.string.forge_roadmap_status_maybe
    suggestion.status == "done" -> R.string.forge_roadmap_status_done
    suggestion.status == "notPlanned" -> R.string.forge_roadmap_status_not_planned
    else -> null
}

private const val MAX_SUGGESTION = 500

@Composable
private fun PhaseSection(titleRes: Int, icon: ImageVector, items: List<RoadmapItem>) {
    if (items.isEmpty()) return
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = Forge.colors.accent, modifier = Modifier.size(18.dp))
        SectionHeader(stringResource(titleRes), Modifier.padding(start = 0.dp))
    }
    items.forEach { item ->
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                Icon(ROADMAP_ICONS[item.icon] ?: Icons.Rounded.Map, contentDescription = null,
                     tint = areaTint(item.area), modifier = Modifier.size(24.dp))
                Column(Modifier.weight(1f)) {
                    Text(item.title, style = Forge.type.headline.copy(fontWeight = FontWeight.SemiBold),
                         color = Forge.colors.text)
                    if (item.line.isNotEmpty()) {
                        Text(item.line, style = Forge.type.body, color = Forge.colors.textSecondary)
                    }
                    RoadmapDates.dayText(item.since)?.let {
                        Text(stringResource(R.string.forge_roadmap_started, it), style = Forge.type.caption,
                             color = Forge.colors.textTertiary)
                    }
                }
            }
        }
    }
}

@Composable
private fun IssueGroup(titleRes: Int, rows: List<RoadmapIssue>, noteRes: Int?) {
    if (rows.isEmpty()) return
    SectionHeader(stringResource(titleRes))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        rows.forEach { IssueRow(it) }
    }
    if (noteRes != null) {
        Text(stringResource(noteRes), style = Forge.type.caption, color = Forge.colors.textSecondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space2))
    }
}

@Composable
private fun IssueRow(issue: RoadmapIssue) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Text(issue.title, style = Forge.type.body, color = Forge.colors.text)
        val parts = buildList {
            add("#${issue.number}")
            add(stringResource(statusRes(issue.status)))
            RoadmapDates.dayText(issue.opened ?: issue.closed)?.let { add(it) }
            issue.fixedIn?.let { add(stringResource(R.string.forge_roadmap_in_version, it)) }
        }
        Text(parts.joinToString(" · "), style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
}
