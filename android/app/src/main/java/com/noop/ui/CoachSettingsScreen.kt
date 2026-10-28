package com.noop.ui

import com.noop.R
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * Coach settings, split out of [CoachScreen] so the coach tab is the conversation and nothing else
 * (#2243). Holds the three surfaces that used to sit above the transcript: the data-sharing consent,
 * the editable coach instructions, and the morning brief.
 *
 * Connection management (the provider pill and Disconnect) deliberately stays on [CoachScreen].
 * Disconnect is the only route back to the setup card, which is the only place a key can be typed,
 * and #2206 is the iOS version of what happens when that control is put somewhere the screen does
 * not render.
 *
 * The first-run setup card deliberately stays on [CoachScreen]. It is the only route to a working
 * coach, and someone who has not connected a provider arrives on the Coach tab, not here, so moving
 * it would leave that screen an empty chat with no way out.
 *
 * NOT a card-for-card twin of `CoachSettingsView`, which carries five. The two further opt-ins this
 * screen lacks are a pre-existing divergence, not part of the #2243 move: the on-device-signals toggle
 * already lives on the main Settings screen on Android (NoopPrefs.coachSignals, read by both
 * CoachViewModel.send and CoachBriefScheduler), and the Gemini multimodal chart has no Android UI at
 * all, only the unread NoopPrefs.coachMultimodal stub. Worth folding in, separately.
 *
 * Reached by the strip on the coach page rather than from the More drawer: the drawer groups mirror
 * the iOS More list one-for-one, and this hangs off Coach on both platforms instead. Swift twin:
 * `CoachSettingsView`.
 */
@Composable
// `vm` is deliberately REQUIRED. The default `viewModel()` resolves against the NavBackStackEntry, so
// it would hand this destination its own CoachViewModel rather than the conversation's, which is the
// defect this screen shipped with: consent is held in memory and read by `send`, so a revoke made
// against a second instance persisted to storage and still left the conversation sending on the old
// one. AppRoot passes the Coach entry's view model.
fun CoachSettingsScreen(vm: CoachViewModel, onOpenIdentity: (() -> Unit)? = null, onOpenMemory: (() -> Unit)? = null,
                        onOpenInfo: (() -> Unit)? = null, onOpenGoals: (() -> Unit)? = null) {
    val context = LocalContext.current

    // The brief settings are read from prefs on show, the same as the coach page did before the
    // split: this screen can now be the first one to render them.
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.loadBriefSettings(context) }

    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    ScreenScaffold(
        title = stringResource(R.string.coach_settings),
        subtitle = stringResource(R.string.coach_settings_subtitle),
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
    ) {
        // No unconfigured branch: the strip that reaches this screen is drawn inside CoachChat, which
        // only renders once a provider is connected, and nothing here can disconnect one (Disconnect
        // stays on the coach page). A "not connected yet" card would be unreachable, and the Swift twin
        // has no equivalent.
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            CoachFeatureCard(vm = vm)
            CoachTodayCard(vm = vm)
            CoachModelCard(vm = vm)
            CoachBackgroundModelsCard(vm = vm)
            if (onOpenIdentity != null) CoachIdentityRow(vm, onOpenIdentity)
            if (onOpenGoals != null) CoachNavRow(stringResource(R.string.coach_goals_journey), stringResource(R.string.coach_goals_journey_subtitle), onOpenGoals)
            if (onOpenMemory != null) CoachNavRow(stringResource(R.string.coach_memory), stringResource(R.string.coach_memory_subtitle), onOpenMemory)
            CoachConsentCard(vm = vm)
            CoachSharedSettingsCards(vm = vm)
            CoachInstructions(vm = vm)
            MorningSuggestionSwitch()
            MorningBriefCard(vm = vm)
            CoachRemindersCard()
            CoachUsageCard(vm = vm)
            if (onOpenInfo != null) {
                val info by vm.info.collectAsStateWithLifecycle()
                androidx.compose.runtime.LaunchedEffect(Unit) { vm.loadInfo() }
                info?.let { CoachNavRow(it.infoTitle, "", onOpenInfo) }
            }
        }
    }
}

/**
 * Which model answers, and the control that refreshes the list of them.
 *
 * This lives HERE rather than on the setup card because of where a key exists. The setup card renders
 * only while `isConfigured` is false, which for a cloud provider means no key is stored, and the
 * Refresh control is gated on having one: `enabled = hasKey` inside a screen that only appears when
 * `!hasKey` can never be true. So for OpenAI, Anthropic and Gemini that button was permanently
 * disabled, and the live catalogue those three publish was unreachable. A key exists by definition on
 * this screen, so both the picker and the refresh work.
 *
 * The PROVIDER deliberately stays on the setup card. A stored key records which provider it belongs to
 * and is never sent anywhere else (AiKeyStore.read(ctx, provider)), so switching provider here would
 * leave a key that cannot be used and a screen that cannot fix it.
 */
@Composable
private fun CoachModelCard(vm: CoachViewModel) {
    val context = LocalContext.current
    val provider by vm.provider.collectAsStateWithLifecycle()
    val model by vm.model.collectAsStateWithLifecycle()
    val availableModels by vm.availableModels.collectAsStateWithLifecycle()
    val refreshingModels by vm.refreshingModels.collectAsStateWithLifecycle()

    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    uiString(R.string.l10n_coach_screen_provider_displayname_model_8b39f761, provider.displayName, model),
                    style = NoopType.subhead, color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                RefreshModelsButton(
                    refreshing = refreshingModels,
                    enabled = vm.hasKey(context),
                    onClick = { vm.refreshModels(context) },
                )
            }
            ModelDropdown(
                models = availableModels,
                selected = model,
                onSelect = { vm.selectModel(context, it) },
            )
            // "Test connection" (`connectionTestRow`): one tiny request in the coach's own format.
            val settings by vm.coachSettings.collectAsStateWithLifecycle()
            val test by vm.connectionTest.collectAsStateWithLifecycle()
            val labels = settings?.labels.orEmpty()
            if (labels["test"] != null) {
                val running = test?.second?.isEmpty() == true
                Text(labels["test"].orEmpty(), style = NoopType.subhead, color = if (running) Palette.textTertiary else Palette.accent,
                     modifier = Modifier.clip(RoundedCornerShape(50)).clickable(enabled = !running) { vm.testConnection(context) }
                         .padding(vertical = 4.dp))
                test?.let { (ok, line) ->
                    Text(if (running) labels["testing"].orEmpty() else line, style = NoopType.footnote,
                         color = when { running -> Palette.textTertiary; ok -> Palette.statusPositive; else -> Palette.statusCritical })
                }
            }
        }
    }
}

/**
 * Data-access consent, off by default; no metrics are sent until this is on.
 *
 * The ON line NAMES what a session carries, rather than saying "workouts" and leaving the reader to
 * guess how much that is. It used to mean a count and an effort figure; since #2033 it means the
 * sport, how long, how far and how hard, per session. That is a materially different disclosure and
 * the toggle is the only place someone is asked to agree to it, so it says so instead of making them
 * read a PR to find out.
 */
@Composable
private fun CoachConsentCard(vm: CoachViewModel) {
    val context = LocalContext.current
    val consent by vm.consent.collectAsStateWithLifecycle()
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(uiString(R.string.l10n_coach_screen_let_the_coach_use_my_data_405d1188), style = NoopType.subhead, color = Palette.textPrimary)
                Text(
                    if (consent) uiString(R.string.coach_consent_on)
                    else uiString(R.string.coach_consent_off),
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
            androidx.compose.material3.Switch(
                checked = consent,
                onCheckedChange = { vm.setConsent(context, it) },
            )
        }
    }
}

/**
 * The switch for the morning suggestion on Today (`morningSuggestionBar`), kept by the shared coach under iOS's
 * `coach.morningSuggestion` key, with its words from the core.
 */
@Composable
private fun MorningSuggestionSwitch() {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val scale = androidx.compose.runtime.remember { UnitPrefs.effortScale(context).raw }
    var card by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<com.noop.core.CoreCoach.Morning?>(null) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        card = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { com.noop.core.CoreCoach.morning(scale) }
    }
    val c = card ?: return
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(c.labels["setting"].orEmpty(), style = NoopType.subhead, color = Palette.textPrimary)
                Text(c.labels["note"].orEmpty(), style = NoopType.footnote, color = Palette.textTertiary)
            }
            androidx.compose.material3.Switch(
                checked = c.on,
                onCheckedChange = { on ->
                    scope.launch {
                        card = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                            com.noop.core.CoreCoach.morning(scale, "set", on = on)
                        } ?: card
                    }
                },
            )
        }
    }
}

/**
 * K5: the scheduled morning-brief notification settings, an enable switch, a time-of-day chip, and
 * an explicit "Generate now" action. Mirrors the daily-debug-export settings row shape
 * ([DebugExportScheduler]) and the Swift twin's `morningBriefBar`.
 */
@Composable
private fun MorningBriefCard(vm: CoachViewModel) {
    val context = LocalContext.current
    val enabled by vm.briefEnabled.collectAsStateWithLifecycle()
    val minutes by vm.briefMinutes.collectAsStateWithLifecycle()
    val generating by vm.briefGenerating.collectAsStateWithLifecycle()
    val status by vm.briefStatus.collectAsStateWithLifecycle()

    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(R.string.coach_morning_brief), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        if (enabled)
                            stringResource(R.string.coach_morning_brief_desc)
                        else stringResource(R.string.coach_morning_brief_off),
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
                androidx.compose.material3.Switch(
                    checked = enabled,
                    onCheckedChange = { vm.setBriefEnabled(context, it) },
                )
            }
            if (enabled) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.coach_morning_brief_time), style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                    TimeChip(
                        minutes = minutes,
                        accessibilityLabel = "Morning brief time",
                        onPicked = { vm.setBriefMinutes(context, it) },
                    )
                }
                Text(
                    stringResource(R.string.coach_morning_brief_best_effort),
                    style = NoopType.caption, color = Palette.textTertiary,
                )
                CoachPrimaryButton(
                    label = if (generating) stringResource(R.string.coach_generating) else stringResource(R.string.coach_generate_now),
                    enabled = !generating,
                    onClick = { vm.generateBriefNow(context) },
                )
                if (status != null) {
                    Text(status.orEmpty(), style = NoopType.footnote, color = Palette.textTertiary)
                }
            }
        }
    }
}

/**
 * Editable system prompt, the instructions that frame the coach. Collapsed by default; expanding
 * reveals a multi-line field bound to the view model (edits persist to [NoopPrefs] and take effect on
 * the next message) plus a Reset-to-default control.
 */
@Composable
private fun CoachInstructions(vm: CoachViewModel) {
    val context = LocalContext.current
    val prompt by vm.systemPrompt.collectAsStateWithLifecycle()
    val hasCustom by vm.hasCustomPrompt.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.loadSystemPrompt() }
    var expanded by remember { mutableStateOf(false) }

    val headerInteraction = remember { MutableInteractionSource() }
    // Read outside the semantics block: uiString is @Composable and that lambda is not a
    // composable scope. Routing through resources rather than literals also keeps the i18n audit
    // green, which the plain (non --ci) run does not check.
    val collapseLabel = uiString(R.string.l10n_coach_settings_screen_collapse_coach_instructions_0933974a)
    val editLabel = uiString(R.string.l10n_coach_settings_screen_edit_coach_instructions_63a38c3a)
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(if (expanded) 10.dp else 0.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .liquidPress(headerInteraction)
                    .clickable(interactionSource = headerInteraction, indication = null) { expanded = !expanded }
                    .semantics {
                        contentDescription = if (expanded)
                            collapseLabel else editLabel
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_coach_screen_coach_instructions_28a07975), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        if (hasCustom) uiString(R.string.l10n_coach_settings_screen_customised_your_edited_instructions_frame_every_reply_bab91200)
                        else uiString(R.string.l10n_coach_settings_screen_edit_how_the_coach_thinks_and_talks_takes_5104835d),
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
                Icon(
                    Icons.Filled.ArrowDropDown,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(20.dp),
                )
            }

            if (expanded) {
                OutlinedTextField(
                    value = prompt,
                    onValueChange = { vm.setSystemPrompt(context, it) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 140.dp, max = 260.dp)
                        .semantics { contentDescription = uiString(R.string.l10n_coach_screen_coach_instructions_editor_b8f3ad31) },
                    textStyle = NoopType.body,
                    singleLine = false,
                    colors = coachFieldColors(),
                    shape = RoundedCornerShape(14.dp),
                )
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(
                        onClick = { vm.resetSystemPrompt(context) },
                        enabled = hasCustom,
                    ) {
                        Text(
                            uiString(R.string.l10n_coach_screen_reset_to_default_39c90eb7),
                            style = NoopType.footnote,
                            color = if (hasCustom) Palette.accent else Palette.textTertiary,
                        )
                    }
                }
            }
        }
    }
}

/** The way into the coach's identity, as the iOS Coaching page's "Coach identity" row, with its avatar. */
@Composable
private fun CoachIdentityRow(vm: CoachViewModel, onOpen: () -> Unit) {
    val identity by vm.identity.collectAsStateWithLifecycle()
    androidx.compose.runtime.LaunchedEffect(Unit) { vm.loadCoachName() }
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onOpen),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CoachIdentityAvatar(identity, 40.dp)
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.coach_identity), style = NoopType.headline, color = Palette.textPrimary)
                Text(identity?.name ?: stringResource(R.string.coach_identity_subtitle), style = NoopType.footnote,
                     color = Palette.textSecondary)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Palette.textTertiary)
        }
    }
}

/** A row into one of the coach's own pages, in the shape of the identity row. */
@Composable
private fun CoachNavRow(title: String, subtitle: String, onOpen: () -> Unit) {
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Row(Modifier.fillMaxWidth().clickable(onClick = onOpen), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                if (subtitle.isNotEmpty()) Text(subtitle, style = NoopType.footnote, color = Palette.textSecondary)
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Palette.textTertiary)
        }
    }
}


/**
 * The daily check-in (`checkInBar`: a reminder at a fixed time or at the learned wake time) and plan reminders
 * (`planReminderBar`: at the time set for an agreed session). Both are local notifications with no provider call;
 * switching one on asks for the notification permission where Android needs it.
 */
@Composable
private fun CoachRemindersCard() {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var checkIn by remember { mutableStateOf(CoachReminders.checkIn(context)) }
    var planOn by remember { mutableStateOf(CoachReminders.planRemindersEnabled(context)) }
    var info by remember { mutableStateOf<com.noop.core.CoreCoach.CheckIn?>(null) }
    val permission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) {}
    fun askPermission() {
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED) {
            permission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    androidx.compose.runtime.LaunchedEffect(checkIn.timeMinutes, checkIn.afterWake) {
        info = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.noop.core.CoreRead.open(context); com.noop.core.CoreCoach.checkIn(checkIn.timeMinutes)
        }
    }
    val l = info?.labels ?: return
    fun save(next: CoachReminders.CheckIn) {
        val learned = next.copy(wakeMinutes = info?.wakeMinutes ?: next.wakeMinutes)
        checkIn = learned
        CoachReminders.setCheckIn(context, learned, l["notifTitle"], l["notifBody"])
    }
    val notificationsOff = !androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()

    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(l["title"].orEmpty(), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(l[if (checkIn.enabled) "on" else "off"].orEmpty(), style = NoopType.footnote, color = Palette.textTertiary)
                }
                androidx.compose.material3.Switch(checked = checkIn.enabled, onCheckedChange = {
                    if (it) askPermission()
                    save(checkIn.copy(enabled = it))
                })
            }
            if (checkIn.enabled) {
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Palette.surfaceInset).padding(3.dp)) {
                    listOf(false to l["fixed"], true to l["wake"]).forEach { (wake, label) ->
                        val selected = checkIn.afterWake == wake
                        Text(label.orEmpty(), style = NoopType.footnote,
                             color = if (selected) Palette.textPrimary else Palette.textSecondary,
                             textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                             modifier = Modifier.weight(1f).clip(RoundedCornerShape(10.dp))
                                 .background(if (selected) Palette.surfaceOverlay else Color.Transparent)
                                 .clickable { save(checkIn.copy(afterWake = wake)) }.padding(vertical = 7.dp))
                    }
                }
                if (checkIn.afterWake) {
                    Text(l["wakeReadout"].orEmpty(), style = NoopType.footnote, color = Palette.textTertiary)
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(l["time"].orEmpty(), style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                        TimeChip(minutes = checkIn.timeMinutes, accessibilityLabel = l["time"].orEmpty(),
                                 onPicked = { save(checkIn.copy(timeMinutes = it)) })
                    }
                }
                if (notificationsOff) Text(l["denied"].orEmpty(), style = NoopType.footnote, color = Palette.statusCritical)
            }
        }
    }
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(l["planTitle"].orEmpty(), style = NoopType.subhead, color = Palette.textPrimary)
                    Text((if (planOn) l["planOn"] else l["planOff"]).orEmpty(), style = NoopType.footnote, color = Palette.textTertiary)
                }
                androidx.compose.material3.Switch(checked = planOn, onCheckedChange = { on ->
                    if (on) askPermission()
                    planOn = on
                    val scale = UnitPrefs.effortScale(context).raw
                    scope.launch(kotlinx.coroutines.Dispatchers.IO) { CoachReminders.setPlanReminders(context, on, scale) }
                })
            }
            if (planOn && notificationsOff) Text(l["planDenied"].orEmpty(), style = NoopType.footnote, color = Palette.statusCritical)
        }
    }
}
