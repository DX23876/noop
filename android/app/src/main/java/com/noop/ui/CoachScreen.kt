package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.painterResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.SportsGymnastics
import androidx.compose.material.icons.filled.Warning
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.EditCalendar
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.offset
import com.noop.core.CoreCoach
import androidx.compose.ui.graphics.Brush
import androidx.compose.animation.core.animateFloat
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.ai.AiProvider
import com.noop.ai.ChatMsg
import com.noop.ai.CustomAiAuthHeader

/**
 * AI Coach, the single opt-in, bring-your-own-key feature.
 *
 * Two states:
 *  - No key saved → a setup card: masked key field, provider choice, model dropdown, Save, and a
 *    one-line privacy note.
 *  - Key saved → the chat: transcript of user/assistant bubbles, suggested-prompt chips, an input
 *    row with Send (disabled while sending), an error line in red, and a reset-key affordance.
 *
 * Everything is composed from the locked design system (ScreenScaffold / NoopCard / NoopType /
 * Palette / StatePill / SegmentedPillControl), dark Material3.
 */
@Composable
fun CoachScreen(vm: CoachViewModel = viewModel(), onOpenSettings: () -> Unit = {},
                trailing: (@Composable () -> Unit)? = null, onOpenPlan: (() -> Unit)? = null,
                onOpenHistory: (() -> Unit)? = null, onOpenBreathe: (() -> Unit)? = null,
                onOpenLive: (() -> Unit)? = null, onOpenGoals: (() -> Unit)? = null,
                onGoalOnboarding: (() -> Unit)? = null, onReviewDraft: ((String, String?) -> Unit)? = null) {
    val context = LocalContext.current
    val keyVersion by vm.keyVersion.collectAsStateWithLifecycle()
    val provider by vm.provider.collectAsStateWithLifecycle()
    val customConnected by vm.customConnected.collectAsStateWithLifecycle()
    // Re-evaluate the gate whenever the stored key, provider, or custom-connect state changes.
    val configured = remember(keyVersion, provider, customConnected) { vm.isConfigured(context) }
    // #1862: a question handed over by the Today launcher sheet. Consumed once — `consume()` clears it —
    // so a recomposition cannot resend it, and only when the coach can actually send, so an unconfigured
    // handoff degrades to showing setup rather than a failed request. Swift twin: CoachView's task.
    LaunchedEffect(configured) {
        val handed = CoachHandoff.consume()
        if (handed != null && configured) vm.send(context, handed)
        val card = CoachHandoff.consumeCard()
        if (card != null && configured) vm.askAboutCard(context, card.first, card.second)
    }
    // Same day-cycle gate as the liquid Today: the time-of-day sky settles behind the top content when the
    // user hasn't opted out; otherwise the scaffold paints the plain dark canvas.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    ScreenScaffold(
        // The connected chat opens on its own header row, as on iOS; the setup keeps the page title.
        title = if (configured) null else uiString(R.string.l10n_coach_screen_coach_b32c9ad3),
        trailing = trailing,
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the liquid sky sits behind the
        // header and the cards float over the flat canvas below. Reuses the shared LiquidScreenSky() slot
        // verbatim; when the day-cycle background is off, the scaffold paints the plain surface instead.
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
        scrollable = !configured,
    ) {
        if (!configured) {
            CoachSetup(vm = vm)
        } else {
            CoachChat(vm = vm, onOpenSettings = onOpenSettings, onOpenPlan = onOpenPlan, onOpenHistory = onOpenHistory,
                      onOpenBreathe = onOpenBreathe, onOpenLive = onOpenLive, onOpenGoals = onOpenGoals,
                      onGoalOnboarding = onGoalOnboarding, onReviewDraft = onReviewDraft)
        }
    }
}

// MARK: - Setup (no key saved)

@Composable
private fun CoachSetup(vm: CoachViewModel) {
    val context = LocalContext.current
    val provider by vm.provider.collectAsStateWithLifecycle()
    val model by vm.model.collectAsStateWithLifecycle()
    val availableModels by vm.availableModels.collectAsStateWithLifecycle()
    val refreshingModels by vm.refreshingModels.collectAsStateWithLifecycle()
    val customBaseUrl by vm.customBaseUrl.collectAsStateWithLifecycle()
    val customAuthHeader by vm.customAuthHeader.collectAsStateWithLifecycle()
    // The setup card had no error line at all, so every way this screen can fail before a key is
    // committed failed silently: a Refresh the provider turned away, a Connect to a server that wants
    // auth. The wearer saw a button do nothing. The chat has had one since the beginning; this is the
    // half that was missing.
    val error by vm.error.collectAsStateWithLifecycle()
    var keyInput by remember { mutableStateOf("") }
    val isCustom = provider == AiProvider.CUSTOM

    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                Text(uiString(R.string.l10n_coach_screen_connect_a_provider_6967f288), style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                if (isCustom)
                    "Point the coach at any OpenAI-compatible server: a local model (Ollama, LM " +
                        "Studio, llama.cpp) keeps everything on your device; an API key is optional."
                else
                    "Bring your own API key. It is stored encrypted on this device and only used to " +
                        "send your question plus a short summary of your metrics to the provider you pick.",
                style = NoopType.subhead, color = Palette.textSecondary,
            )

            // Provider choice.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Overline("Provider")
                SegmentedPillControl(
                    items = AiProvider.entries,
                    selection = provider,
                    label = { it.displayName },
                    onSelect = { vm.selectProvider(context, it) },
                )
            }

            // Server URL, Custom (local LLM) only.
            if (isCustom) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Server URL")
                    OutlinedTextField(
                        value = customBaseUrl,
                        onValueChange = { vm.setCustomBaseUrl(context, it) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .semantics { contentDescription = uiString(R.string.l10n_coach_screen_server_url_1d5d1eff) },
                        placeholder = { Text("http://localhost:11434/v1", style = NoopType.body, color = Palette.textTertiary) },
                        textStyle = NoopType.mono(13f),
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        colors = coachFieldColors(),
                        shape = RoundedCornerShape(14.dp),
                    )
                }

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline(uiString(R.string.l10n_coach_screen_key_header_3f2a9b10))
                    SegmentedPillControl(
                        items = CustomAiAuthHeader.entries,
                        selection = customAuthHeader,
                        label = { it.displayName },
                        onSelect = { vm.setCustomAuthHeader(context, it) },
                    )
                    Text(
                        uiString(R.string.l10n_coach_screen_use_bearer_for_most_local_servers_4429ab64),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
            }

            // Model dropdown + live-list refresh.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Overline("Model")
                    Spacer(Modifier.weight(1f))
                    RefreshModelsButton(
                        refreshing = refreshingModels,
                        // Cloud providers need a saved key to fetch; a local server just needs a URL.
                        enabled = if (isCustom) customBaseUrl.isNotBlank() else vm.hasKey(context),
                        onClick = { vm.refreshModels(context) },
                    )
                }
                ModelDropdown(
                    models = availableModels,
                    selected = model,
                    onSelect = { vm.selectModel(context, it) },
                )
            }

            // Masked key field, optional for a local Custom server.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Overline(if (isCustom) "API Key (optional)" else "API Key")
                CoachKeyField(
                    value = keyInput,
                    onValueChange = { keyInput = it },
                    placeholder = if (isCustom) "Only if your server requires one"
                                  else "Paste your ${provider.displayName} key",
                )
            }

            // Connect (Custom) / Save key (cloud).
            if (isCustom) {
                CoachPrimaryButton(
                    label = uiString(R.string.l10n_coach_screen_connect_b65463cb),
                    enabled = customBaseUrl.isNotBlank(),
                    onClick = {
                        if (keyInput.isNotBlank()) vm.saveKey(context, keyInput)
                        vm.connectCustom(context)
                    },
                )
            } else {
                CoachPrimaryButton(
                    label = uiString(R.string.l10n_coach_screen_save_key_f5216b3a),
                    enabled = keyInput.isNotBlank(),
                    onClick = { vm.saveKey(context, keyInput) },
                )
            }

            // Whatever the last attempt from THIS card ran into. No repair affordance beside it:
            // unlike the chat, the key field is already on screen, which is the whole point of the card.
            val errorMsg = error
            if (errorMsg != null) {
                Text(
                    errorMsg,
                    style = NoopType.subhead,
                    color = Palette.statusCritical,
                    modifier = Modifier.semantics {
                        contentDescription = uiString(R.string.l10n_coach_screen_coach_error_error_ad9c8c46, errorMsg)
                    },
                )
            }

            // Privacy note, one line, always visible.
            PrivacyNote(local = isCustom)
        }
    }
}

// MARK: - Chat (key saved)

@Composable
private fun CoachChat(vm: CoachViewModel, onOpenSettings: () -> Unit, onOpenPlan: (() -> Unit)? = null,
                      onOpenHistory: (() -> Unit)? = null, onOpenBreathe: (() -> Unit)? = null,
                      onOpenLive: (() -> Unit)? = null, onOpenGoals: (() -> Unit)? = null,
                      onGoalOnboarding: (() -> Unit)? = null, onReviewDraft: ((String, String?) -> Unit)? = null) {
    val context = LocalContext.current
    val messages by vm.messages.collectAsStateWithLifecycle()
    val sending by vm.sending.collectAsStateWithLifecycle()
    val error by vm.error.collectAsStateWithLifecycle()
    // Also controls the editor's rejection hint when the wearer opens Update key manually.
    val keyRejected by vm.keyRejected.collectAsStateWithLifecycle()
    val provider by vm.provider.collectAsStateWithLifecycle()
    val model by vm.model.collectAsStateWithLifecycle()
    val suggestions by vm.suggestions.collectAsStateWithLifecycle()
    val coachName by vm.coachName.collectAsStateWithLifecycle()
    val recovery by vm.recovery.collectAsStateWithLifecycle()
    val canDeepen by vm.canDeepen.collectAsStateWithLifecycle()
    val chrome by vm.chrome.collectAsStateWithLifecycle()
    // The first-use note, once, before the first conversation (`CoachFirstUseSheet`); "more" opens the full page.
    val info by vm.info.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.loadInfo() }
    var infoOpen by remember { mutableStateOf(false) }
    info?.takeIf { !it.acknowledged }?.let { i ->
        if (infoOpen) {
            androidx.compose.ui.window.Dialog(onDismissRequest = { infoOpen = false }) {
                // Done stays below the scrolling text, so it is reachable without reading to the end.
                Column(Modifier.clip(RoundedCornerShape(18.dp)).background(Palette.surfaceBase).padding(20.dp)) {
                    Column(Modifier.weight(1f, fill = false).verticalScroll(androidx.compose.foundation.rememberScrollState())) {
                        CoachInfoPage(vm)
                    }
                    TextButton(onClick = { infoOpen = false }, modifier = Modifier.align(Alignment.End)) { Text(i.done) }
                }
            }
        } else {
            CoachFirstUseNote(i, onMore = { infoOpen = true }, onGotIt = { vm.loadInfo(acknowledge = true) })
        }
    }
    // The drafts the coach left for review (`hasPendingDraft`), read again whenever a reply finishes.
    var drafts by remember { mutableStateOf<com.noop.core.CoreCoachDrafts.Drafts?>(null) }
    LaunchedEffect(sending) {
        if (!sending) drafts = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.noop.core.CoreCoachDrafts.drafts(context)
        }
    }
    // The goal setup, offered once to a coach with no goal yet, after the first-use note (`goalOnboarding`).
    val acknowledged = info?.acknowledged == true
    LaunchedEffect(acknowledged) {
        if (!acknowledged || onGoalOnboarding == null) return@LaunchedEffect
        val offer = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.noop.core.CoreGoalOnboarding.run(com.noop.core.CoreGoalOnboarding.Draft(), 0.0)?.offer
        }
        if (offer == true) onGoalOnboarding()
    }
    // The plan dot and the consent hint change on the pages this chat opens, so read them again on every return.
    LaunchedEffect(Unit) { vm.loadCoachName(); vm.refreshChrome() }
    // K15: the composer draft is persisted to SharedPreferences so it survives an app relaunch.
    // Restored on first composition, saved on every change. Keyed identically to the iOS twin.
    val draftPrefs = remember { context.getSharedPreferences("noop_coach_draft", android.content.Context.MODE_PRIVATE) }
    var input by remember { mutableStateOf(draftPrefs.getString("draft", "") ?: "") }
    // K2: confirmation gate for the destructive "Clear conversation" action.
    var showClearConfirm by remember { mutableStateOf(false) }
    // The corrected key, typed into the editor the rejection message opens. Separate from `input` so a
    // half-typed question is not lost while fixing the key, and cleared on save so a secret does not
    // sit in composition state after it has been stored.
    var keyFix by remember { mutableStateOf("") }
    var showKeyEditor by remember { mutableStateOf(false) }

    // Refresh the contextual chips whenever the chat empties (so a fresh sync updates them) and
    // once on first show. Best-effort; the VM falls back to the generic set on any failure.
    LaunchedEffect(messages.isEmpty()) {
        if (messages.isEmpty()) vm.refreshSuggestions()
    }

    // K14: vibrate when a reply arrives (sending goes true → false with messages present).
    var wasSending by remember { mutableStateOf(false) }
    LaunchedEffect(sending) {
        if (wasSending && !sending && messages.isNotEmpty()) {
            val vibrator = context.getSystemService(android.content.Context.VIBRATOR_SERVICE)
                as android.os.Vibrator
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    android.os.VibrationEffect.createOneShot(50, android.os.VibrationEffect.DEFAULT_AMPLITUDE)
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(50)
            }
        }
        wasSending = sending
    }

    // K2 + K5 ordering matters and both gate on an EMPTY transcript, so this is ONE coroutine,
    // sequential: restore whatever the prior launch persisted FIRST, retire it if it belongs to an
    // earlier day, THEN surface a brief the scheduled notification already generated (if any) — so K5
    // never overwrites K2's restore, and never appends a duplicate brief onto a transcript K2 just
    // repopulated.
    LaunchedEffect(Unit) {
        vm.loadPersistedMessagesIfNeeded()
        // The load runs once per PROCESS, so on a process kept alive overnight it returns without
        // re-checking the day and leaves yesterday's chat in memory, which K5 then refuses to replace.
        // Retiring here is what lets today's brief reach the screen at all (#2087).
        vm.retireStaleConversationIfNeeded()
        // loadBriefSettings is NOT called here any more: it only populates the brief's UI state, which
        // CoachSettingsScreen owns since #2243, and consumeScheduledBriefIfAny reads storage directly.
        vm.consumeScheduledBriefIfAny(context)
    }

    val identity by vm.identity.collectAsStateWithLifecycle()
    // The transcript scrolls under a still header and composer, as on iOS, and follows the newest words.
    val transcript = androidx.compose.foundation.rememberScrollState()
    LaunchedEffect(messages.size, messages.lastOrNull()?.text?.length, sending, transcript.maxValue) {
        transcript.animateScrollTo(transcript.maxValue)
    }
    androidx.compose.runtime.CompositionLocalProvider(LocalCoachIdentity provides identity) {
    Column(Modifier.fillMaxSize().imePadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {

        // One compact glass row, as the iOS chat header: the coach's avatar (breathing while a reply is
        // written), its name with "Thinking…" in place of the provider line, New chat, and the rest in an
        // overflow menu. The plan book and history come in through the host's `trailing` slot.
        CoachHeaderRow(
            sending = sending,
            title = coachName.ifEmpty { uiString(R.string.l10n_coach_screen_coach_b32c9ad3) },
            providerLine = stringResource(R.string.coach_your_coach),
            canStartNew = messages.isNotEmpty() && !sending,
            onPlan = onOpenPlan,
            planWaiting = chrome.planWaiting,
            planLabel = chrome.planLabel,
            onHistory = onOpenHistory,
            onGoals = onOpenGoals,
            onNew = { vm.clearConversation() },
            onSettings = onOpenSettings,
            onUpdateKey = { showKeyEditor = !showKeyEditor; if (!showKeyEditor) keyFix = "" },
            onDisconnect = { vm.disconnect(context) },
        )

        if (showClearConfirm) {
            AlertDialog(
                onDismissRequest = { showClearConfirm = false },
                title = { Text(stringResource(R.string.coach_clear_conversation_confirm)) },
                text = { Text(stringResource(R.string.coach_clear_conversation_message)) },
                confirmButton = {
                    TextButton(onClick = { vm.clearConversation(); showClearConfirm = false }) {
                        Text(stringResource(R.string.coach_clear_action), color = Palette.statusCritical)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showClearConfirm = false }) { Text(stringResource(R.string.l10n_coach_screen_cancel_77dfd213)) }
                },
            )
        }

        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(transcript), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        // Transcript or empty-state with suggested prompts.
        if (messages.isEmpty()) {
            // The iOS greeting: the coach's portrait, who it is, what it reads, then the suggestions.
            Column(
                Modifier.fillMaxWidth().padding(top = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                CoachAvatar(size = 96.dp)
                Text(stringResource(R.string.coach_hi_im, coachName.ifEmpty { uiString(R.string.l10n_coach_screen_coach_b32c9ad3) }),
                     style = NoopType.title2, color = Palette.textPrimary)
                Text(stringResource(R.string.coach_empty_intro), style = NoopType.subhead, color = Palette.textSecondary,
                     textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
            if (sending) ThinkingBubble()
            SuggestedPrompts(prompts = suggestions, onPick = { input = it })
        } else {
            Column(Modifier.fillMaxWidth()) {
                val lastAssistant = messages.lastOrNull { it.role == "assistant" }?.id
                val lastUser = messages.lastOrNull { it.role == "user" }?.id
                messages.forEachIndexed { index, msg ->
                    val previous = messages.getOrNull(index - 1)
                    val continuation = msg.role == "assistant" && previous?.role == "assistant"
                    if (index > 0) Spacer(Modifier.height(if (continuation) 6.dp else 16.dp))
                    // A time stamp before the first turn and wherever more than half an hour passed (`timeSeparator`).
                    if (msg.date > 0 && (previous == null || previous.date <= 0 || msg.date - previous.date > 30 * 60)) {
                        TimeSeparator(msg.date)
                        Spacer(Modifier.height(10.dp))
                    }
                    ChatBubble(
                        msg, vm, groupStart = msg.role == "assistant" && !continuation,
                        isLastAssistant = msg.id == lastAssistant, isLastUser = msg.id == lastUser,
                        sending = sending, canDeepen = canDeepen, onReclaim = { q -> input = q },
                        receiptLabels = chrome.receiptLabels,
                    )
                }
                // The typing indicator only until the reply's first words arrive; then the reply itself streams.
                if (sending && messages.lastOrNull()?.role != "assistant") {
                    Spacer(Modifier.height(16.dp))
                    ThinkingBubble()
                }
                Spacer(Modifier.height(10.dp))
                // K7: follow-up suggestion chips after each assistant reply (when not mid-send); right after a
                // card read the engine's metric-specific ones come first, as on iOS.
                if (!sending && messages.isNotEmpty() && messages.last().role == "assistant") {
                    ActionRow(chrome.actionLabels, onBreathe = onOpenBreathe, onLive = onOpenLive, onSchedule = onOpenPlan,
                              drafts = drafts, onReview = onReviewDraft)
                    Spacer(Modifier.height(10.dp))
                    SuggestedPrompts(prompts = chrome.cardSuggestions.ifEmpty { vm.followUpSuggestions }, onPick = { input = it })
                }
            }
        }

        // Error line (red). Capture into a stable local first: `error` is a state-backed nullable, and
        // the `semantics {}` contentDescription is a DEFERRED closure run later during the accessibility
        // pass — by then a recomposition can have cleared `error`, so `error!!` inside the lambda would
        // NPE (#1074). The local `errorMsg` is a fixed non-null snapshot the lambda can't null out from
        // under it.
        // The standing hint that answers are generic while data access is off (`consentOffBanner`).
        if (!chrome.dataConsent && chrome.consentOff.isNotEmpty()) ConsentOffBanner(chrome, onOpenSettings)

        val errorMsg = error
        if (errorMsg != null) {
            // As the iOS error banner: what went wrong, then the way forward the typed error offers.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusCritical, modifier = Modifier.size(18.dp))
                    Text(
                        errorMsg,
                        style = NoopType.subhead,
                        color = Palette.statusCritical,
                        modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_coach_screen_coach_error_error_ad9c8c46, errorMsg) },
                    )
                }
                when (recovery?.first) {
                    "reauthenticate" -> Text(
                        stringResource(R.string.coach_enter_key_again), style = NoopType.footnote, color = Palette.statusCritical,
                        modifier = Modifier.clip(RoundedCornerShape(50)).clickable { showKeyEditor = true }.padding(vertical = 4.dp),
                    )
                    "retry", null -> RetryButton(recovery?.second, enabled = !sending) { vm.regenerate() }
                    else -> Unit
                }
            }
        }
        if (keyRejected || showKeyEditor) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (keyRejected) {
                    Text(
                        uiString(R.string.coach_key_rejected_hint),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
                CoachKeyField(
                    value = keyFix,
                    onValueChange = { keyFix = it },
                    placeholder = uiString(R.string.coach_key_rejected_placeholder, provider.displayName),
                )
                CoachPrimaryButton(
                    label = uiString(R.string.coach_key_rejected_action),
                    enabled = keyFix.isNotBlank(),
                    onClick = {
                        vm.saveKey(context, keyFix)
                        keyFix = ""
                        showKeyEditor = false
                    },
                )
                if (showKeyEditor && !keyRejected) {
                    TextButton(onClick = { showKeyEditor = false; keyFix = "" }) {
                        Text(stringResource(R.string.l10n_coach_screen_cancel_77dfd213))
                    }
                }
            }
        }

        }

        // Input row + Send, a frosted overlay surface so the composer reads as a docked input bar.
        // K4: the mic button (on-device voice input) sits between the text field and Send.
        MicComposerRow(
            input = input,
            onInputChange = {
                input = it
                // K15: persist the draft so it survives an app relaunch.
                draftPrefs.edit().putString("draft", it).apply()
                if (error != null) vm.clearError()
            },
            sending = sending,
            onStop = { vm.stopReply() },
            onSend = {
                vm.send(context, input)
                input = ""
                // K15: clear the persisted draft on send.
                draftPrefs.edit().remove("draft").apply()
            },
        )

        // K12: rough token estimate shown when the draft is non-empty.
        if (input.isNotBlank()) {
            vm.estimatedTokens(input)?.let { tokens ->
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                    horizontalArrangement = Arrangement.Start,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Filled.Speed,
                        contentDescription = null,
                        modifier = Modifier.size(10.dp),
                        tint = Palette.textTertiary,
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        stringResource(R.string.coach_token_estimate, tokens),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                    if (tokens > 8000) {
                        Text(
                            stringResource(R.string.coach_token_warning),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                }
            }
        }

        // Privacy note repeated under the input so it's always on screen.
        PrivacyNote(local = provider == AiProvider.CUSTOM)
    }
    }
}

// MARK: - Chat bubbles

/** The coach's face, breathing while a reply is written, from the identity the chat provides. */
@Composable
internal fun CoachAvatar(size: androidx.compose.ui.unit.Dp, breathing: Boolean = false) {
    // Held still under battery saver or reduced motion, as iOS holds the avatar still under Reduce Motion.
    val pulse = if (breathing && !rememberPoseStill()) {
        val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "coachBreath")
        transition.animateFloat(
            initialValue = 1f, targetValue = 1.06f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                androidx.compose.animation.core.tween(1100), androidx.compose.animation.core.RepeatMode.Reverse),
            label = "coachBreathScale",
        ).value
    } else 1f
    Box(Modifier.graphicsLayer { scaleX = pulse; scaleY = pulse }) {
        CoachIdentityAvatar(LocalCoachIdentity.current, size)
    }
}

/** The iOS chat header: avatar, the chat's name with what the coach is doing under it, New chat, overflow. */
@Composable
private fun CoachHeaderRow(
    sending: Boolean,
    title: String,
    providerLine: String,
    canStartNew: Boolean,
    onPlan: (() -> Unit)?,
    planWaiting: Int = 0,
    planLabel: String = "",
    onHistory: (() -> Unit)?,
    onGoals: (() -> Unit)? = null,
    onNew: () -> Unit,
    onSettings: () -> Unit,
    onUpdateKey: () -> Unit,
    onDisconnect: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(28.dp))
            .background(Palette.surfaceBase.copy(alpha = 0.32f))
            .border(1.dp, Palette.textPrimary.copy(alpha = 0.18f), RoundedCornerShape(28.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.clip(CircleShape).clickable(onClick = onSettings)
                .semantics { contentDescription = uiString(R.string.coach_settings) }) {
            CoachAvatar(size = 36.dp, breathing = sending)
        }
        Column(Modifier.weight(1f)) {
            // The page title already says "Coach"; the row names what answers: the model, then its provider.
            Text(title, style = NoopType.headline, color = Palette.textPrimary, maxLines = 1,
                 overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)

            // One fixed-height line: "Thinking…" takes the provider line's place, so the header never grows.
            Text(if (sending) uiString(R.string.l10n_coach_screen_thinking_a60d9c9c) else providerLine,
                 style = NoopType.footnote, color = if (sending) Palette.accent else Palette.textTertiary,
                 maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        }
        if (onPlan != null) {
            // The dot means a suggestion waits for the wearer's answer, as on iOS.
            Box(Modifier.clip(CircleShape).clickable(onClick = onPlan).padding(6.dp)
                    .semantics { contentDescription = planLabel.ifEmpty { uiString(R.string.forge_cp_title) } }) {
                Icon(Icons.Filled.CalendarMonth, contentDescription = null,
                     tint = if (planWaiting > 0) Palette.accent else Palette.textSecondary, modifier = Modifier.size(22.dp))
                if (planWaiting > 0) {
                    Box(Modifier.align(Alignment.TopEnd).offset(x = 3.dp, y = (-2).dp).size(6.dp).clip(CircleShape)
                            .background(Palette.accent))
                }
            }
        }
        Icon(
            Icons.Filled.EditNote,
            contentDescription = stringResource(R.string.coach_new_chat),
            tint = if (canStartNew) Palette.statusPositive else Palette.textTertiary.copy(alpha = 0.5f),
            modifier = Modifier.clip(CircleShape)
                .clickable(enabled = canStartNew, onClick = onNew).padding(6.dp).size(22.dp),
        )
        Box {
            Icon(
                Icons.Filled.MoreHoriz,
                contentDescription = stringResource(R.string.coach_more_actions),
                tint = Palette.textSecondary,
                modifier = Modifier.clip(CircleShape).clickable { menu = true }.padding(6.dp).size(22.dp),
            )
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (onHistory != null) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.coach_history)) }, onClick = { menu = false; onHistory() })
                }
                // The goal and its journey, as the iOS chat's overflow offers them.
                if (onGoals != null) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.coach_goals_journey)) }, onClick = { menu = false; onGoals() })
                }
                DropdownMenuItem(text = { Text(uiString(R.string.coach_settings)) }, onClick = { menu = false; onSettings() })
                DropdownMenuItem(text = { Text(uiString(R.string.coach_key_rejected_action)) }, onClick = { menu = false; onUpdateKey() })
                DropdownMenuItem(text = { Text(uiString(R.string.l10n_coach_screen_disconnect_ed28e068)) },
                                 onClick = { menu = false; onDisconnect() })
            }
        }
    }
}

/**
 * One turn, in the iOS chat's shape. The question is a bubble in the accent colour with its sender-side
 * corner pulled tight; the coach's reply has NO bubble, it is text to read beside the coach's avatar, shown
 * once at the top of a run of replies. Long-press for Copy, Share and (on a reply) Save to journal.
 */
@Composable
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun ChatBubble(msg: ChatMsg, vm: CoachViewModel, groupStart: Boolean = true, isLastAssistant: Boolean = false,
                       isLastUser: Boolean = false, sending: Boolean = false, canDeepen: Boolean = false,
                       onReclaim: (String) -> Unit = {}, receiptLabels: Map<String, String> = emptyMap()) {
    val isUser = msg.role == "user"
    val context = LocalContext.current
    val clipboardManager = androidx.compose.ui.platform.LocalClipboardManager.current
    var showMenu by remember { mutableStateOf(false) }
    val longPress = Modifier.combinedClickable(
        interactionSource = remember { MutableInteractionSource() }, indication = null,
        onClick = {}, onLongClick = { showMenu = true },
    )
    val menu: @Composable () -> Unit = {
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.coach_copy_action)) },
                onClick = {
                    clipboardManager.setText(androidx.compose.ui.text.AnnotatedString(msg.text))
                    showMenu = false
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.coach_share_action)) },
                onClick = {
                    val sendIntent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(android.content.Intent.EXTRA_TEXT, msg.text)
                    }
                    context.startActivity(android.content.Intent.createChooser(sendIntent, "Share Coach advice"))
                    showMenu = false
                },
            )
            if (!isUser) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.coach_save_to_journal)) },
                    onClick = { vm.saveAdviceToJournal(msg.text); showMenu = false },
                )
            }
            // Only the last reply can be regenerated and only the last question taken back, as on iOS: doing
            // either further up would silently drop every exchange after it.
            if (!isUser && isLastAssistant && !sending) {
                DropdownMenuItem(text = { Text(stringResource(R.string.coach_regenerate)) },
                                 onClick = { showMenu = false; vm.regenerate() })
                if (canDeepen) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.coach_look_closer)) },
                                     onClick = { showMenu = false; vm.regenerate(deeper = true) })
                }
            }
            if (isUser && isLastUser && !sending) {
                DropdownMenuItem(text = { Text(stringResource(R.string.coach_edit_ask_again)) },
                                 onClick = { showMenu = false; vm.reclaimLastQuestion(onReclaim) })
            }
        }
    }
    if (isUser) {
        val shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp, bottomEnd = 6.dp, bottomStart = 20.dp)
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.weight(1f).widthIn(min = 32.dp))
            Box(
                Modifier
                    .widthIn(max = 340.dp)
                    .clip(shape)
                    .background(Brush.verticalGradient(listOf(Palette.accent, Palette.accent.copy(alpha = 0.86f))))
                    .then(longPress)
                    .padding(horizontal = 16.dp, vertical = 12.dp)
                    .semantics { contentDescription = uiString(R.string.coach_you_said, msg.text) },
            ) {
                Text(msg.text, style = NoopType.body, color = Palette.surfaceBase)
                menu()
            }
        }
    } else {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // "The coach got in touch": an unprompted message would otherwise read as a reply to nothing.
            msg.gotInTouch?.let {
                Text(it, style = NoopType.caption, color = Palette.textTertiary, modifier = Modifier.padding(start = 34.dp))
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (groupStart) CoachAvatar(size = 26.dp) else Spacer(Modifier.width(26.dp))
                Box(Modifier.weight(1f).widthIn(max = 640.dp).then(longPress).padding(vertical = 2.dp)) {
                    when {
                        msg.chart != null -> ChatChart(msg.chart)
                        msg.card != null -> ChatCard(msg.card)
                        // Render the Coach's Markdown (bold/lists/headings) instead of raw symbols (#149), with the
                        // caret under the reply while it is still being written (`CoachStreamCaret`).
                        else -> Column {
                            CoachMarkdown(msg.text, color = Palette.textPrimary)
                            if (sending && isLastAssistant) StreamCaret()
                        }
                    }
                    menu()
                }
            }
            if (msg.evidence.isNotEmpty()) EvidenceChain(msg, Modifier.padding(start = 34.dp))
            if (msg.saved.isNotEmpty()) MemoryReceipt(msg, vm, receiptLabels, Modifier.padding(start = 34.dp))
        }
    }
}

/** The blinking accent bar under a reply being written; it holds still under battery saver or reduced motion. */
@Composable
private fun StreamCaret() {
    val still = rememberPoseStill()
    val alpha = if (still) 1f else androidx.compose.animation.core.rememberInfiniteTransition(label = "caret").animateFloat(
        1f, 0.15f, androidx.compose.animation.core.infiniteRepeatable(
            androidx.compose.animation.core.tween(600), androidx.compose.animation.core.RepeatMode.Reverse), label = "caret",
    ).value
    Box(Modifier.padding(top = 4.dp).size(width = 2.dp, height = 15.dp).graphicsLayer { this.alpha = alpha }
            .clip(RoundedCornerShape(1.dp)).background(Palette.accent))
}

/** A time stamp between turns, as the iOS chat's `timeSeparator`: the time today, the date before. */
@Composable
private fun TimeSeparator(epochSeconds: Double) {
    val instant = java.time.Instant.ofEpochSecond(epochSeconds.toLong())
    val zone = java.time.ZoneId.systemDefault()
    val day = instant.atZone(zone).toLocalDate()
    val text = if (day == java.time.LocalDate.now(zone))
        java.time.format.DateTimeFormatter.ofLocalizedTime(java.time.format.FormatStyle.SHORT).format(instant.atZone(zone))
    else java.time.format.DateTimeFormatter.ofLocalizedDateTime(java.time.format.FormatStyle.MEDIUM, java.time.format.FormatStyle.SHORT)
        .format(instant.atZone(zone))
    Text(text, style = NoopType.caption, color = Palette.textTertiary, textAlign = androidx.compose.ui.text.style.TextAlign.Center,
         modifier = Modifier.fillMaxWidth())
}

/**
 * What this reply saved to memory, with the iOS receipt's controls: confirm a fact that waits for it, correct it
 * (which confirms it too) or forget it. Facts are looked up by id in the core, so a forgotten one drops out.
 */
@Composable
private fun MemoryReceipt(msg: ChatMsg, vm: CoachViewModel, labels: Map<String, String>, modifier: Modifier = Modifier) {
    var editing by remember(msg.id) { mutableStateOf<ChatMsg.Saved?>(null) }
    var draft by remember(msg.id) { mutableStateOf("") }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        msg.saved.forEach { fact ->
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.Psychology, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(14.dp))
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(fact.line, style = NoopType.caption, color = Palette.textTertiary)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        if (!fact.confirmed) ReceiptControl(labels["confirm"], Palette.accent) { vm.receipt("confirm", fact.id) }
                        ReceiptControl(labels["edit"], Palette.textTertiary) { draft = fact.text; editing = fact }
                        ReceiptControl(labels["forget"], Palette.textTertiary) { vm.receipt("remove", fact.id) }
                    }
                }
            }
        }
    }
    editing?.let { fact ->
        AlertDialog(
            onDismissRequest = { editing = null },
            title = { Text(labels["editTitle"].orEmpty()) },
            text = { OutlinedTextField(draft, { draft = it }, colors = noopFieldColors()) },
            confirmButton = {
                TextButton(onClick = { vm.receipt("update", fact.id, draft); editing = null }) { Text(labels["save"].orEmpty()) }
            },
            dismissButton = { TextButton(onClick = { editing = null }) { Text(labels["cancel"].orEmpty()) } },
        )
    }
}

@Composable
private fun ReceiptControl(label: String?, color: Color, onClick: () -> Unit) {
    Text(label.orEmpty(), style = NoopType.caption, color = color,
         modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onClick).padding(vertical = 4.dp))
}

/** The standing fast paths from advice to doing something (`actionRow`): Breathe, Live Session, Schedule a session. */
@Composable
private fun ActionRow(labels: Map<String, String>, onBreathe: (() -> Unit)?, onLive: (() -> Unit)?, onSchedule: (() -> Unit)?,
                      drafts: com.noop.core.CoreCoachDrafts.Drafts? = null, onReview: ((String, String?) -> Unit)? = null) {
    val context = LocalContext.current
    // Hidden while Live Sessions are switched off, as on iOS, so the chip never opens nothing.
    val live = onLive?.takeIf { LiveSessionPrefs.enabled(context) }
    val l = drafts?.labels.orEmpty()
    val chips = listOfNotNull(
        // The drafts waiting first, as `actionRow` orders them: goal, routine, workout.
        drafts?.goalId?.let { id -> onReview?.let { r -> Triple(Icons.Filled.TrackChanges, l["reviewDraft"] ?: "", { r("goal", id) }) } },
        drafts?.routine?.let { onReview?.let { r -> Triple(Icons.Filled.FitnessCenter, l["reviewRoutine"] ?: "", { r("routine", null) }) } },
        drafts?.workout?.let { onReview?.let { r -> Triple(Icons.Filled.SportsGymnastics, l["reviewWorkout"] ?: "", { r("workout", null) }) } },
        onBreathe?.let { Triple(Icons.Filled.Air, labels["breathe"], it) },
        live?.let { Triple(Icons.Filled.MonitorHeart, labels["live"], it) },
        onSchedule?.let { Triple(Icons.Filled.EditCalendar, labels["schedule"], it) },
    ).filter { !it.second.isNullOrEmpty() }
    if (chips.isEmpty()) return
    Row(Modifier.horizontalScroll(androidx.compose.foundation.rememberScrollState()).padding(start = 34.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        chips.forEach { (icon, label, action) ->
            Row(
                Modifier.clip(RoundedCornerShape(50)).background(Palette.surfaceInset).clickable(onClick = action)
                    .padding(horizontal = 9.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(icon, contentDescription = null, tint = Palette.textSecondary, modifier = Modifier.size(14.dp))
                Text(label.orEmpty(), style = NoopType.caption, color = Palette.textSecondary)
            }
        }
    }
}

/** Data access is off: answers are generic, and "Turn on" leads to the coach settings (`consentOffBanner`). */
@Composable
private fun ConsentOffBanner(chrome: CoreCoach.Chrome, onOpenSettings: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Palette.surfaceOverlay).padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
        Text(chrome.consentOff, style = NoopType.subhead, color = Palette.textSecondary, modifier = Modifier.weight(1f))
        Text(chrome.turnOn, style = NoopType.footnote, color = Palette.accent,
             modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onOpenSettings).padding(vertical = 2.dp))
    }
}

/** "Grounded in N of your data sources", expanding to the sources the reply read (`evidenceChain`). */
@Composable
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
private fun EvidenceChain(msg: ChatMsg, modifier: Modifier = Modifier) {
    var open by remember(msg.id) { mutableStateOf(false) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            Modifier.clip(RoundedCornerShape(50)).clickable { open = !open }.padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(Icons.Filled.Verified, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(14.dp))
            Text(msg.evidenceHeader.orEmpty(), style = NoopType.caption, color = Palette.textTertiary)
            Icon(if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null,
                 tint = Palette.textTertiary, modifier = Modifier.size(14.dp))
        }
        if (open) {
            androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp),
                                                       verticalArrangement = Arrangement.spacedBy(6.dp)) {
                msg.evidence.forEach {
                    Text(it, style = NoopType.caption, color = Palette.textSecondary,
                         modifier = Modifier.clip(RoundedCornerShape(50)).background(Palette.surfaceBase.copy(alpha = 0.55f))
                             .padding(horizontal = 10.dp, vertical = 5.dp))
                }
            }
        }
    }
}

/** A chart the coach drew (`CoachChartBubble`): the metric's line over its days, on the card surface. */
@Composable
private fun ChatChart(chart: ChatMsg.Chart) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).frostedCardSurface(tint = Palette.accent, cornerRadius = 18.dp)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(chart.title, style = NoopType.headline, color = Palette.textPrimary)
        val pts = chart.points
        if (pts.size >= 2) {
            val lineColor = Palette.accent
            androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(140.dp)) {
                val x0 = pts.first().first; val x1 = pts.last().first
                val span = (chart.hi - chart.lo).takeIf { it > 0 } ?: 1.0
                fun x(t: Double) = ((t - x0) / (x1 - x0).coerceAtLeast(1.0) * size.width).toFloat()
                fun y(v: Double) = (size.height - (v - chart.lo) / span * size.height).toFloat()
                val path = androidx.compose.ui.graphics.Path()
                pts.forEachIndexed { i, p -> if (i == 0) path.moveTo(x(p.first), y(p.second)) else path.lineTo(x(p.first), y(p.second)) }
                drawPath(path, lineColor, style = androidx.compose.ui.graphics.drawscope.Stroke(width = 3.dp.toPx(),
                         cap = androidx.compose.ui.graphics.StrokeCap.Round))
                drawCircle(lineColor, radius = 4.dp.toPx(), center = androidx.compose.ui.geometry.Offset(x(pts.last().first), y(pts.last().second)))
            }
        }
    }
}

/** A card the coach chose (`CoachCardBubble`): title, the app's own value, a caption and up to four rows. */
@Composable
private fun ChatCard(card: ChatMsg.Card) {
    val tint = when (card.tint) {
        "charge" -> Palette.chargeColor
        "effort" -> Palette.effortColor
        "rest" -> Palette.restColor
        else -> Palette.accent
    }
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).frostedCardSurface(tint = tint, cornerRadius = 18.dp).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Overline(card.title.uppercase(), color = tint)
        Text(card.value, style = NoopType.title2, color = Palette.textPrimary)
        card.caption?.let { Text(it, style = NoopType.footnote, color = Palette.textSecondary) }
        card.rows.forEach { (label, value) ->
            Row(Modifier.fillMaxWidth()) {
                Text(label, style = NoopType.footnote, color = Palette.textSecondary, modifier = Modifier.weight(1f))
                Text(value, style = NoopType.footnote, color = Palette.textPrimary)
            }
        }
    }
}

/** Retry, held back for the wait the provider asked for (`retryButton`). */
@Composable
private fun RetryButton(waitSeconds: Int?, enabled: Boolean, onRetry: () -> Unit) {
    var left by remember(waitSeconds) { mutableStateOf(waitSeconds ?: 0) }
    LaunchedEffect(waitSeconds) { while (left > 0) { kotlinx.coroutines.delay(1000); left -= 1 } }
    val ready = left <= 0
    Row(
        Modifier.clip(RoundedCornerShape(50)).clickable(enabled = enabled && ready, onClick = onRetry).padding(vertical = 4.dp)
            .graphicsLayer { alpha = if (ready) 1f else 0.6f },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(Icons.Filled.Refresh, contentDescription = null, tint = Palette.statusCritical, modifier = Modifier.size(16.dp))
        Text(if (ready) stringResource(R.string.coach_retry) else stringResource(R.string.coach_retry_in, left),
             style = NoopType.footnote, color = Palette.statusCritical)
    }
}

/** Three dots beside the coach's avatar until the first words of the reply arrive. */
@Composable
private fun ThinkingBubble() {
    val still = rememberPoseStill()
    val transition = androidx.compose.animation.core.rememberInfiniteTransition(label = "typing")
    Row(
        modifier = Modifier.fillMaxWidth()
            .semantics { contentDescription = uiString(R.string.l10n_coach_screen_coach_is_thinking_aaf91547) },
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CoachAvatar(size = 26.dp, breathing = true)
        Row(
            Modifier.clip(RoundedCornerShape(50)).background(Palette.surfaceBase.copy(alpha = 0.6f))
                .border(1.dp, Palette.textPrimary.copy(alpha = 0.16f), RoundedCornerShape(50))
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            repeat(3) { i ->
                // Three steady dots under battery saver or reduced motion; a pulse otherwise.
                val alpha = if (still) 0.7f else transition.animateFloat(
                    initialValue = 0.25f, targetValue = 1f,
                    animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                        androidx.compose.animation.core.tween(600, delayMillis = i * 180),
                        androidx.compose.animation.core.RepeatMode.Reverse),
                    label = "dot$i",
                ).value
                Box(Modifier.size(7.dp).graphicsLayer { this.alpha = alpha }.clip(CircleShape).background(Palette.accent))
            }
        }
    }
}

// MARK: - Suggested prompts

/**
 * #1862: shared with the Today Coach launcher sheet — see [CoachPrompts].
 *
 * Two hardcoded lists would have drifted the moment either was edited, and the launcher's whole purpose
 * is to be a shortcut INTO this screen rather than a second, subtly different Coach.
 */
internal val SUGGESTED_PROMPTS: List<String> get() = CoachPrompts.SUGGESTIONS

/** The suggestions as wrapping capsules over the backdrop, as the iOS chip cloud. */
@Composable
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
private fun SuggestedPrompts(prompts: List<String>, onPick: (String) -> Unit) {
    androidx.compose.foundation.layout.FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        prompts.forEach { prompt ->
            val shape = RoundedCornerShape(50)
            val chipInteraction = remember { MutableInteractionSource() }
            Text(
                prompt,
                style = NoopType.subhead,
                color = Palette.textPrimary,
                modifier = Modifier
                    .clip(shape)
                    .background(Palette.surfaceBase.copy(alpha = 0.55f))
                    .border(1.dp, Palette.textPrimary.copy(alpha = 0.16f), shape)
                    .liquidPress(chipInteraction)
                    .clickable(interactionSource = chipInteraction, indication = null) { onPick(prompt) }
                    .padding(horizontal = 14.dp, vertical = 9.dp)
                    .semantics { contentDescription = uiString(R.string.l10n_coach_screen_suggested_prompt_prompt_379c0b15, prompt) },
            )
        }
    }
}

// MARK: - Model dropdown

@Composable
internal fun ModelDropdown(
    models: List<String>,
    selected: String,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    var showCustom by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(14.dp)
    val triggerInteraction = remember { MutableInteractionSource() }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(Palette.surfaceInset)
                .border(1.dp, Palette.hairline, shape)
                .liquidPress(triggerInteraction)
                .clickable(interactionSource = triggerInteraction, indication = null) { expanded = true }
                .padding(horizontal = 14.dp, vertical = 12.dp)
                .semantics { contentDescription = uiString(R.string.l10n_coach_screen_model_selected_tap_to_change_043056c1, selected) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(selected, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = Palette.textSecondary)
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(Palette.surfaceOverlay),
        ) {
            models.forEach { m ->
                DropdownMenuItem(
                    text = {
                        Text(
                            m,
                            style = NoopType.body,
                            color = if (m == selected) Palette.accent else Palette.textPrimary,
                        )
                    },
                    onClick = {
                        onSelect(m)
                        expanded = false
                    },
                )
            }
            // Free-text escape hatch, any model id the provider accepts can be entered.
            DropdownMenuItem(
                text = { Text(uiString(R.string.l10n_coach_screen_custom_dce04fd3), style = NoopType.body, color = Palette.textSecondary) },
                onClick = {
                    expanded = false
                    showCustom = true
                },
            )
        }
    }

    if (showCustom) {
        CustomModelDialog(
            initial = selected,
            onDismiss = { showCustom = false },
            onConfirm = { id ->
                showCustom = false
                if (id.isNotBlank()) onSelect(id)
            },
        )
    }
}

// MARK: - Custom model dialog (free-text id)

@Composable
private fun CustomModelDialog(
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_coach_screen_custom_model_2e3bedea), style = NoopType.headline, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    uiString(R.string.l10n_coach_screen_enter_any_model_id_the_provider_dce4bbcb),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = uiString(R.string.l10n_coach_screen_custom_model_id_6ffe2740) },
                    placeholder = { Text(uiString(R.string.l10n_coach_screen_e_g_gpt_4o_1da2e4d2), style = NoopType.body, color = Palette.textTertiary) },
                    textStyle = NoopType.mono(13f),
                    singleLine = true,
                    colors = coachFieldColors(),
                    shape = RoundedCornerShape(14.dp),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(text.trim()) },
                enabled = text.isNotBlank(),
            ) {
                Text(uiString(R.string.l10n_coach_screen_use_model_8d558ce2), style = NoopType.headline, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_coach_screen_cancel_77dfd213), style = NoopType.subhead, color = Palette.textSecondary)
            }
        },
    )
}

// MARK: - Refresh models (fetch live list)

@Composable
internal fun RefreshModelsButton(
    refreshing: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(50)
    val active = enabled && !refreshing
    val refreshInteraction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .let {
                if (active)
                    it
                        .liquidPress(refreshInteraction)
                        .clickable(interactionSource = refreshInteraction, indication = null, onClick = onClick)
                else it
            }
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .semantics { contentDescription = uiString(R.string.l10n_coach_screen_fetch_models_from_provider_6654e1a0) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (refreshing) {
            CircularProgressIndicator(modifier = Modifier.size(13.dp), strokeWidth = 2.dp, color = Palette.accent)
        } else {
            Icon(
                Icons.Filled.Refresh,
                contentDescription = null,
                tint = if (active) Palette.accent else Palette.textTertiary,
                modifier = Modifier.size(14.dp),
            )
        }
        Text(
            if (refreshing) "Fetching…" else "Refresh models",
            style = NoopType.caption,
            color = if (active) Palette.textPrimary else Palette.textTertiary,
        )
    }
}

// MARK: - Key field

@Composable
private fun CoachKeyField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = uiString(R.string.l10n_coach_screen_api_key_hidden_f3cde531) },
        placeholder = { Text(placeholder, style = NoopType.body, color = Palette.textTertiary) },
        textStyle = NoopType.mono(13f),
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        colors = coachFieldColors(),
        shape = RoundedCornerShape(14.dp),
    )
}

// MARK: - Buttons

@Composable
internal fun CoachPrimaryButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(14.dp)
    val bg = if (enabled) Palette.accent else Palette.accent.copy(alpha = Palette.disabledOpacity)
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp)
            .clip(shape)
            .background(bg)
            .let {
                if (enabled)
                    it
                        .liquidPress(interaction)
                        .clickable(interactionSource = interaction, indication = null, onClick = onClick)
                else it
            }
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = NoopType.headline, color = Palette.surfaceBase)
    }
}

// MARK: - K4: Voice input composer row (mic button + text field + send)

/**
 * K4: The composer row with a mic button (on-device voice input) between the text field and Send.
 * Mirrors the iOS `CoachView.composer` + `micButton` twin. The mic button:
 *  - requests RECORD_AUDIO at runtime on first tap (via [rememberLauncherForActivityResult]),
 *  - starts/stops [CoachVoiceInput], which uses `createOnDeviceSpeechRecognizer` behind an
 *    `isOnDeviceRecognitionAvailable` gate (API 31+); below that the button is not composed at all,
 *  - streams the partial transcript into the text field live,
 *  - on stop, appends the finalized transcript to the draft (not replace, so it composes with
 *    typed text).
 * Only the resulting TEXT ever reaches the AI provider — no new network path, no audio egress. That
 * is a guarantee rather than a preference: `createOnDeviceSpeechRecognizer` cannot fall back to a
 * server, where the `EXTRA_PREFER_OFFLINE` this line used to name was a hint the platform could ignore.
 */
@Composable
private fun MicComposerRow(
    input: String,
    onInputChange: (String) -> Unit,
    sending: Boolean,
    onSend: () -> Unit,
    onStop: () -> Unit = {},
) {
    val context = LocalContext.current
    var isRecording by remember { mutableStateOf(false) }
    var voiceStatus by remember { mutableStateOf<String?>(null) }

    // The voice controller is remembered for the lifetime of the composer; destroyed on leave.
    val voiceInput = remember {
        CoachVoiceInput(
            context = context,
            onPartial = { partial -> onInputChange(partial) },
            onFinal = { final ->
                val trimmed = final.trim()
                if (trimmed.isNotEmpty()) {
                    // Append to the draft (not replace) so voice composes with typed text.
                    val merged = if (input.isBlank()) trimmed else "$input $trimmed"
                    onInputChange(merged)
                }
            },
            onError = { msg -> voiceStatus = msg },
        )
    }
    // Release the recognizer when the composer leaves composition.
    androidx.compose.runtime.DisposableEffect(voiceInput) {
        onDispose { voiceInput.destroy() }
    }

    // Runtime RECORD_AUDIO permission launcher — raised on the first mic tap if not yet granted.
    val permLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            voiceInput.start()
            isRecording = true
        } else {
            voiceStatus = context.getString(R.string.coach_voice_permission_denied)
        }
    }

    // A floating glass capsule, as the iOS composer: the voice button leading, the field on an inset
    // surface, and one round button that sends, or stops a reply while it streams.
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(26.dp))
            .frostedCardSurface(tint = Palette.accent, cornerRadius = 26.dp)
            .border(1.dp, Palette.textPrimary.copy(alpha = 0.16f), RoundedCornerShape(26.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // K4: on-device voice input, hidden where on-device recognition is not available.
        if (voiceInput.isAvailable()) {
            MicButton(
                isRecording = isRecording,
                enabled = !sending,
                statusMessage = voiceStatus,
                onClick = {
                    voiceStatus = null
                    if (isRecording) {
                        voiceInput.stop()
                        isRecording = false
                    } else {
                        if (voiceInput.isPermissionGranted()) {
                            voiceInput.start()
                            isRecording = true
                        } else {
                            permLauncher.launch(voiceInput.requiredPermission)
                        }
                    }
                },
            )
        }

        // A flat inset field with one hairline, as iOS draws it (`CoachRadius.field`), not a Material outline.
        var focused by remember { mutableStateOf(false) }
        androidx.compose.foundation.text.BasicTextField(
            value = input,
            onValueChange = onInputChange,
            enabled = !sending,
            textStyle = NoopType.body.copy(color = Palette.textPrimary),
            cursorBrush = androidx.compose.ui.graphics.SolidColor(Palette.accent),
            maxLines = 8,
            modifier = Modifier.weight(1f).onFocusChanged { focused = it.isFocused },
            decorationBox = { inner ->
                Box(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(20.dp))
                        .background(Palette.surfaceInset)
                        .border(1.dp, if (focused) Palette.accent.copy(alpha = 0.6f) else Color.Transparent, RoundedCornerShape(20.dp))
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                ) {
                    if (input.isEmpty()) {
                        Text(
                            if (isRecording) stringResource(R.string.coach_listening) else uiString(R.string.l10n_coach_screen_ask_your_coach_b1577d4c),
                            style = NoopType.body, color = Palette.textTertiary,
                        )
                    }
                    inner()
                }
            },
        )

        SendButton(
            enabled = input.isNotBlank() || sending,
            sending = sending,
            onClick = if (sending) onStop else onSend,
        )
    }

    // Voice status / error line (e.g. "Microphone permission denied" or locale-not-supported).
    if (voiceStatus != null) {
        Text(
            voiceStatus!!,
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

/** The voice button as iOS draws it: a plain microphone glyph, the waveform in Charge while recording. */
@Composable
private fun MicButton(
    isRecording: Boolean,
    enabled: Boolean,
    statusMessage: String?,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val desc = if (isRecording) "Stop voice input" else "Voice input"
    val statusSuffix = statusMessage?.let { stringResource(R.string.coach_status_suffix, it) } ?: ""
    Box(
        modifier = Modifier
            .size(32.dp)
            .clip(CircleShape)
            .let {
                if (enabled) it.clickable(interactionSource = interaction, indication = null, onClick = onClick) else it
            }
            .semantics { contentDescription = desc + statusSuffix },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (isRecording) Icons.Filled.GraphicEq else Icons.Filled.Mic,
            contentDescription = null,
            tint = if (isRecording) Palette.chargeColor else Palette.textSecondary,
            modifier = Modifier.size(if (isRecording) 26.dp else 22.dp),
        )
    }
}

/** One round accent button: an arrow to send, a square to stop a reply mid-stream. */
@Composable
private fun SendButton(enabled: Boolean, sending: Boolean, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .size(40.dp)
            .graphicsLayer { alpha = if (enabled) 1f else 0.4f }
            .clip(CircleShape)
            .background(Palette.accent)
            .let {
                if (enabled)
                    it
                        .liquidPress(interaction)
                        .clickable(interactionSource = interaction, indication = null, onClick = onClick)
                else it
            }
            .semantics {
                contentDescription = if (sending) uiString(R.string.coach_stop_reply)
                    else uiString(R.string.l10n_coach_screen_send_message_c70a890d)
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (sending) Icons.Filled.Stop else Icons.Filled.ArrowUpward,
            contentDescription = null,
            tint = Palette.surfaceBase,
            modifier = Modifier.size(20.dp),
        )
    }
}

// MARK: - Privacy note (one line)

@Composable
private fun PrivacyNote(local: Boolean = false) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(13.dp))
        Text(
            if (local)
                "The coach talks only to the server URL you set. Point it at a local model to " +
                    "keep everything on your device. Nothing is sent until you ask."
            else
                "Private by default: only your question and a short metrics summary are sent, " +
                    "and only after you set a key.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Shared field colors (dark, design-system tinted)

@Composable
internal fun coachFieldColors() = noopFieldColors()
