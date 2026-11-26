package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.R
import com.noop.ui.AppViewModel
import com.noop.ui.CoachSettingsScreen
import com.noop.ui.CoachSettingsSection
import com.noop.ui.CoachViewModel
import com.noop.ui.IntelligenceScreen
import com.noop.ui.ScoringGuideScreen

// Settings shell pages of package 6: "How NOOP scores" and the Coach settings hub.

/**
 * "How NOOP scores" (iOS `ForgeHowScoresView`): one page with a segmented "Explained" / "Your model", the scoring guide
 * and the model the app learned from the wearer's own days.
 */
@Composable
internal fun HowScoresPage(viewModel: AppViewModel, onBack: () -> Unit, title: String) {
    var part by rememberSaveable { mutableIntStateOf(0) }
    Hosted(title, onBack) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.padding(horizontal = ForgeMetrics.screenPadding, vertical = ForgeMetrics.space2)) {
                Segmented(listOf(0, 1), part,
                          label = { stringResource(if (it == 0) R.string.fsp6_how_explained else R.string.fsp6_how_model) },
                          onSelect = { part = it })
            }
            Box(Modifier.weight(1f)) {
                if (part == 0) ScoringGuideScreen(onClose = onBack) else IntelligenceScreen(viewModel)
            }
        }
    }
}

/**
 * The Coach settings as iOS `CoachSettingsView` has them when a provider is set up: a hub of five pages (Connection &
 * model, Goal & Journey, Coaching, Memory, Privacy & data). The identity editor, the memory page and "How Coach works"
 * open from the pages that carry them on iOS. [headPage] puts the Settings page head on the hub (Settings), none from
 * the chat's own settings link.
 */
@Composable
internal fun CoachSettingsPages(title: String, onBack: () -> Unit, headPage: ForgeSettingsPage?) {
    val vm = viewModel<CoachViewModel>()
    // "" is the hub; otherwise the open page: a section name, or identity / memory / info / goals.
    var sub by rememberSaveable { mutableStateOf("") }
    BackHandler(enabled = sub != "") {
        sub = if (sub == "identity") CoachSettingsSection.Coaching.name
              else if (sub == "info") CoachSettingsSection.Privacy.name else ""
    }
    val section = CoachSettingsSection.entries.firstOrNull { it.name == sub }
    when {
        sub == "identity" -> Hosted(stringResource(R.string.coach_identity), { sub = CoachSettingsSection.Coaching.name }) {
            com.noop.ui.CoachIdentityEditor(vm)
        }
        sub == "memory" -> Hosted(stringResource(R.string.coach_memory), { sub = "" }) { com.noop.ui.CoachMemoryPage() }
        sub == "goals" -> ForgeGoalsPage(onBack = { sub = "" })
        sub == "info" -> Hosted(vm.info.collectAsStateWithLifecycle().value?.infoTitle.orEmpty(),
                                { sub = CoachSettingsSection.Privacy.name }) { com.noop.ui.CoachInfoPage(vm) }
        section != null && section != CoachSettingsSection.Hub && section != CoachSettingsSection.All ->
            Hosted(stringResource(when (section) {
                CoachSettingsSection.Connection -> R.string.fsp6_coach_conn
                CoachSettingsSection.Coaching -> R.string.fsp6_coach_coaching
                else -> R.string.fsp6_coach_privacy
            }), { sub = "" }) {
                CoachSettingsScreen(vm, onOpenIdentity = { sub = "identity" }, onOpenInfo = { sub = "info" }, section = section)
            }
        else -> Hosted(title, onBack, head = headPage) {
            CoachSettingsScreen(vm, onOpenMemory = { sub = "memory" }, onOpenGoals = { sub = "goals" },
                                section = CoachSettingsSection.Hub, onOpenSection = { sub = it.name })
        }
    }
}
