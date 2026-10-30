package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.R
import com.noop.core.CoreCoach
import com.noop.core.CoreRead
import com.noop.ui.CoachHandoff
import com.noop.ui.CoachViewModel
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The coach on Today, as iOS shows it: the card (`DashboardCoachCard`: "YOUR COACH SVEA", a greeting and Momentum's
 * own sentence for today) opening the short launcher (`CoachLauncherSheet`: suggestions and a composer that hand the
 * question to the chat). Opening either makes no provider request; the chat sends, as it always did. Shown only
 * while the coach is switched on.
 */
@Composable
internal fun ForgeTodayCoach(viewModel: com.noop.ui.AppViewModel) {
    val context = LocalContext.current
    com.noop.ui.CoachTodayPrefs.version // read, so turning the banner off in Settings hides it here
    if (!NoopPrefs.coachEnabled(context) || !com.noop.ui.CoachTodayPrefs.shown(context) ||
        !com.noop.ui.CoachTodayPrefs.banner(context)) return
    var card by remember { mutableStateOf<CoreCoach.TodayCard?>(null) }
    // The portrait follows the coach's identity, as the name in the overline does.
    var identity by remember { mutableStateOf<CoreCoach.Identity?>(null) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { CoreRead.open(context); card = CoreCoach.todayCard(); identity = CoreCoach.identity() }
    }
    var page by rememberSaveable { mutableStateOf<String?>(null) }
    val c = card ?: return
    val colors = Forge.colors

    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button) { page = "launcher" }) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            // The coach's picture, or the plain sparkle when the wearer turned it off (`coach.todayAvatar`).
            if (com.noop.ui.CoachTodayPrefs.avatar(context)) com.noop.ui.CoachIdentityAvatar(identity, 52.dp)
            else Icon(Icons.Rounded.AutoAwesome, contentDescription = null, tint = colors.accent,
                      modifier = Modifier.size(52.dp).clip(androidx.compose.foundation.shape.CircleShape)
                          .background(colors.accent.copy(alpha = 0.14f)).padding(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(c.overline, style = Forge.type.caption, color = colors.textTertiary)
                Text(c.greeting, style = Forge.type.headline, color = colors.text)
                Text(c.detail, style = Forge.type.subhead, color = colors.textSecondary)
                Text(c.badge, style = Forge.type.caption, color = colors.charge,
                     modifier = Modifier.clip(RoundedCornerShape(50)).background(colors.charge.copy(alpha = 0.14f))
                         .padding(horizontal = 8.dp, vertical = 3.dp))
            }
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = colors.textTertiary)
        }
    }

    page?.let { selected ->
        ForgeOverlayPage(onDismiss = { page = null }) {
            ForgeSceneBackdrop(ForgeBackdrop.Sky) {
                if (selected == "launcher") CoachLauncher(c, onCancel = { page = null }, onHand = { q ->
                    CoachHandoff.pendingPrompt = q
                    page = "chat"
                }, onConnect = { page = "chat" })
                else ForgeCoachChatPages(viewModel, c.title, onBack = { page = null })
            }
        }
    }
}

/**
 * The coach chat as every entry opens it (the Today card, the floating button, Ask coach): the chat, with Breathe
 * and Live from its action row opening over it and Back returning to it.
 */
@Composable
internal fun ForgeCoachChatPages(viewModel: com.noop.ui.AppViewModel, title: String, onBack: () -> Unit) {
    var sub by rememberSaveable { mutableStateOf<String?>(null) }
    when (sub) {
        "breathe" -> {
            BackHandler { sub = null }
            Hosted(stringResource(R.string.nav_breathe), onBack = { sub = null }) { com.noop.ui.BreatheScreen(viewModel) }
        }
        "live" -> {
            BackHandler { sub = null }
            Hosted(stringResource(R.string.nav_live), onBack = { sub = null }) { com.noop.ui.LiveScreen(viewModel) }
        }
        else -> ForgeCoachDestination(title, onBack = onBack, onOpen = { dest ->
            when (dest) {
                MoreDest.Breathe -> sub = "breathe"
                MoreDest.Live -> sub = "live"
                else -> Unit
            }
        })
    }
}

/** The launcher: what the coach reads, the suggestions, and a composer; not connected, the way to the setup. */
@Composable
private fun CoachLauncher(card: CoreCoach.TodayCard, onCancel: () -> Unit, onHand: (String) -> Unit, onConnect: () -> Unit) {
    val context = LocalContext.current
    val vm = viewModel<CoachViewModel>()
    val suggestions by vm.suggestions.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.refreshSuggestions() }
    val configured = remember { vm.isConfigured(context) }
    var draft by rememberSaveable { mutableStateOf("") }
    val colors = Forge.colors
    BackHandler(onBack = onCancel)
    SettingsColumn {
        PageTitle(card.title, onCancel)
        if (!configured) {
            Text(stringResource(R.string.l10n_coach_screen_connect_a_provider_6967f288), style = Forge.type.headline, color = colors.accent,
                 modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onConnect).padding(vertical = 6.dp))
            return@SettingsColumn
        }
        Text(card.intro, style = Forge.type.subhead, color = Forge.sceneInk.secondary)
        ForgeCard(Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                suggestions.forEach { prompt ->
                    Text(prompt, style = Forge.type.body, color = colors.text,
                         modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable { onHand(prompt) }
                             .padding(vertical = 10.dp))
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(draft, { draft = it }, placeholder = { Text(card.ask) }, maxLines = 3,
                              colors = forgeFieldColors(), modifier = Modifier.weight(1f))
            IconButton(onClick = { draft.trim().takeIf { it.isNotEmpty() }?.let(onHand) }, enabled = draft.isNotBlank()) {
                Icon(Icons.Rounded.ArrowUpward, contentDescription = card.ask, tint = colors.accent, modifier = Modifier.size(24.dp))
            }
        }
    }
}
