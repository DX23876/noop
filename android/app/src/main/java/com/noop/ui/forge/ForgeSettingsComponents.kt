package com.noop.ui.forge

import androidx.compose.ui.semantics.heading

import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import com.noop.ingest.WhoopCsvExporter
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.material.icons.rounded.Dashboard
import androidx.compose.runtime.CompositionLocalProvider
import com.noop.ui.LightTokens
import com.noop.ui.DarkTokens
import com.noop.ui.PaletteTokens
import com.noop.ui.HostedPalette
import com.noop.ui.LocalHostedChrome
import com.noop.ui.HostedChrome
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DeviceHub
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.TrackChanges
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Help
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Battery5Bar
import androidx.compose.material.icons.rounded.Functions
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.School
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.SettingsInputAntenna
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Contrast
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Map
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.rounded.Check
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.BuildConfig
import com.noop.BuildIdentity
import com.noop.R
import android.widget.Toast
import androidx.lifecycle.viewmodel.compose.viewModel
import com.noop.analytics.ClockFormatPreference
import com.noop.analytics.DayCycleMode
import com.noop.analytics.SkinTempDisplay
import com.noop.ble.PuffinExperiment
import com.noop.core.CoreShadow
import com.noop.push.SelfHostedPushScreen
import com.noop.ui.AppViewModel
import com.noop.ui.AutomationsScreen
import com.noop.ui.CardAppearance
import com.noop.ui.BackupSyncScreen
import com.noop.ui.ClassicSettingsCard
import com.noop.ui.CoachSettingsScreen
import com.noop.ui.CoachViewModel
import com.noop.ui.DataSourcesScreen
import com.noop.ui.HealthConnectWeightSync
import com.noop.ui.HowNoopWorksScreen
import com.noop.ui.HrvWindow
import com.noop.ui.NoopLimitationsScreen
import com.noop.ui.NotificationsSettingsScreen
import com.noop.ui.Palette
import com.noop.ui.PowerSavingScreen
import com.noop.ui.ScoringGuideScreen
import com.noop.ui.SettingsScreen
import com.noop.ui.StepsCalibrationScreen
import com.noop.ui.TemperatureUnit
import com.noop.ui.TestCentreScreen
import com.noop.ui.WhatsNewSheet
import com.noop.ui.WhoopModelComparisonScreen
import com.noop.ui.setAppIcon
import com.noop.ui.waistCmStep
import com.noop.ui.waistInchesStep
import com.noop.ui.AppLanguage
import com.noop.ui.AppLanguagePrefs
import com.noop.ui.AppearanceMode
import com.noop.ui.AppearancePrefs
import com.noop.ui.ClockPrefs
import com.noop.ui.EffortScale
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitPrefs
import com.noop.ui.UnitSystem
import com.noop.update.UpdateCheck
import com.noop.update.UpdateWatch
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

// Shared rows, cards and controls the Settings pages are built from.

/** The scrolling column every Settings screen sits in, clear of the system bars. */
@Composable
internal fun SettingsColumn(scroll: androidx.compose.foundation.ScrollState = rememberScrollState(),
                            content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxSize().statusBarsPadding().verticalScroll(scroll)
            .padding(horizontal = ForgeMetrics.screenPadding).widthIn(max = ForgeMetrics.maxContentWidth)
            .navigationBarsPadding().padding(bottom = ForgeMetrics.space4),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap),
        content = content,
    )
}

/** One hub row as iOS draws it (`SettingsHubRow`): icon tile, title over subtitle, chevron. */
@Composable
internal fun HubRow(icon: ImageVector, tint: Color, title: String, subtitle: String, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = ForgeMetrics.space4, vertical = ForgeMetrics.space3),
        verticalAlignment = Alignment.CenterVertically) {
        // `appleInspiredMenuIcon`: a 30 pt tile, corner 0.28 of its size, the white symbol at half its size.
        Box(Modifier.size(30.dp).background(tint, RoundedCornerShape(8.4.dp)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
            Text(title, style = Forge.type.body, color = colors.text)
            if (subtitle.isNotEmpty()) Text(subtitle, style = Forge.type.subhead, color = colors.textSecondary)
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
    }
}

@Composable
internal fun HubDivider() {
    HorizontalDivider(color = Forge.colors.divider.copy(alpha = 0.5f), modifier = Modifier.padding(start = ForgeMetrics.space6))
}

/**
 * One settings card as iOS draws it (`SettingsSection`): a title over its blurb, then the rows. A page with one
 * card leaves the title out, since the page title already names it.
 */
@Composable
internal fun SettingsCard(title: String?, blurb: String?, icon: ImageVector? = null, tint: Color? = null,
                          active: Boolean = false, headerAction: (@Composable () -> Unit)? = null,
                          content: @Composable ColumnScope.() -> Unit) {
    // iOS `SettingsSection` in the new design, built as iOS Settings builds a group: a small upper-case header
    // above the card, the controls on the card, and the plain explanation as a footer under it. The icon and
    // tint stay in the signature for the callers; the header carries no icon, as on iOS.
    // iOS spaces its settings groups by the section gap; the column around them uses the card gap, so the
    // difference goes above each group, keeping a footer clear of the next group's header.
    Column(Modifier.fillMaxWidth().padding(top = ForgeMetrics.sectionGap - ForgeMetrics.gap),
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        if (title != null || headerAction != null) {
            Row(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4), verticalAlignment = Alignment.CenterVertically) {
                if (title != null) {
                    Text(title.uppercase(), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
                         color = Forge.colors.textSecondary, modifier = Modifier.semantics { heading() })
                }
                // `Section2` on iOS: an active automation shows a small dot beside its name.
                if (active) {
                    val on = stringResource(R.string.forge_sp_on)
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    Box(Modifier.size(6.dp).background(Forge.colors.charge, CircleShape)
                        .semantics { contentDescription = on })
                }
                // iOS `SettingsSection.headerAction` ("Edit" on Profile): at the header's end, above the card.
                if (headerAction != null) {
                    Spacer(Modifier.weight(1f))
                    headerAction()
                }
            }
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = ForgeMetrics.space4) {
            content()
        }
        if (blurb != null) {
            Text(blurb, style = Forge.type.footnote, color = Forge.colors.textSecondary,
                 modifier = Modifier.padding(horizontal = ForgeMetrics.space4))
        }
    }
}

/**
 * A group header of the Settings index as iOS `ForgeSettingsView.section` draws it: footnote size, semibold,
 * upper case, secondary colour, 16 dp in, a little air above, read as a heading.
 */
@Composable
internal fun SettingsGroupHeader(title: String) {
    Text(title.uppercase(), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
         color = Forge.colors.textSecondary,
         modifier = Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4).padding(top = ForgeMetrics.space2)
             .semantics { heading() })
}

/**
 * The head of a Settings page (iOS `SettingsPageBanner`), as iOS Settings opens its own pages: the page's symbol
 * on a tile in the colour of its row in the index, centred, with one plain line on what the page is for.
 */
@Composable
internal fun SettingsPageHead(page: ForgeSettingsPage) {
    Column(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4).padding(bottom = ForgeMetrics.space2)
               .semantics(mergeDescendants = true) {},
           horizontalAlignment = Alignment.CenterHorizontally,
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Box(Modifier.size(60.dp).background(page.tint(), RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) {
            Icon(page.icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(32.dp))
        }
        Text(stringResource(page.subtitleRes), style = Forge.type.body, color = Forge.colors.textSecondary,
             textAlign = TextAlign.Center)
    }
}

/** A labelled row: the label on the left, its control on the right. */
@Composable
internal fun SettingRow(label: String, control: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.body, color = Forge.colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.weight(1f).padding(end = ForgeMetrics.space2))
        control()
    }
}

/** A row that opens something: title over an optional detail line, then a chevron. */
@Composable
internal fun LinkRow(title: String, detail: String?, busy: Boolean = false, onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
            .clickable(enabled = !busy, role = Role.Button, onClick = onClick)
            .padding(vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.body, color = colors.text)
            if (detail != null) Text(detail, style = Forge.type.footnote, color = colors.textSecondary)
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        if (busy) {
            CircularProgressIndicator(Modifier.size(18.dp), color = colors.textTertiary, strokeWidth = 2.dp)
        } else {
            Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
        }
    }
}

/** A switch with its title and the line that explains it. */
@Composable
internal fun ToggleRow(title: String, detail: String?, checked: Boolean, enabled: Boolean = true,
                       onChange: (Boolean) -> Unit) {
    // The whole row flips the switch, as a SwiftUI Toggle's label does.
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget)
            .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onChange)
            .alpha(if (enabled) 1f else 0.45f)
            .padding(vertical = ForgeMetrics.space1),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = ForgeMetrics.space2), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.body, color = Forge.colors.text)
            if (detail != null) Text(detail, style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
        Switch(checked = checked, onCheckedChange = null, enabled = enabled, colors = settingsSwitchColors())
    }
}

/**
 * A text field in Forge's own colours: the quiet inset grey iOS uses for fields inside a card, not the classic screens'
 * paper tone. A search field on the page itself passes the card surface as [container], so it stands off the canvas.
 */
@Composable
internal fun forgeFieldColors(container: androidx.compose.ui.graphics.Color = Forge.colors.inset) =
    androidx.compose.material3.OutlinedTextFieldDefaults.colors(
    focusedTextColor = Forge.colors.text,
    unfocusedTextColor = Forge.colors.text,
    disabledTextColor = Forge.colors.textTertiary,
    focusedPlaceholderColor = Forge.colors.textTertiary,
    unfocusedPlaceholderColor = Forge.colors.textTertiary,
    focusedLeadingIconColor = Forge.colors.textSecondary,
    unfocusedLeadingIconColor = Forge.colors.textSecondary,
    cursorColor = Forge.colors.accent,
    focusedBorderColor = Forge.colors.accent,
    unfocusedBorderColor = androidx.compose.ui.graphics.Color.Transparent,
    disabledBorderColor = androidx.compose.ui.graphics.Color.Transparent,
    focusedContainerColor = container,
    unfocusedContainerColor = container,
    disabledContainerColor = container,
)

/**
 * The Settings switch: on in the wearer's accent, as iOS tints its settings controls (`appleInspiredTint`
 * "settings.controls"), so a switch reads the same on both phones. The Training area keeps its own green
 * (`forgeSwitchColors`).
 */
@Composable
internal fun settingsSwitchColors() = SwitchDefaults.colors(
    checkedTrackColor = Forge.colors.accent, checkedThumbColor = androidx.compose.ui.graphics.Color.White,
    checkedBorderColor = androidx.compose.ui.graphics.Color.Transparent,
    uncheckedTrackColor = Forge.colors.textTertiary.copy(alpha = 0.35f), uncheckedThumbColor = androidx.compose.ui.graphics.Color.White,
    uncheckedBorderColor = androidx.compose.ui.graphics.Color.Transparent,
)

/** The switch as iOS draws it: green when on, a quiet grey track when off, a white thumb and no outline. */
@Composable
internal fun forgeSwitchColors() = SwitchDefaults.colors(
    checkedTrackColor = ForgeTokens.Color.systemGreen.resolve(), checkedThumbColor = androidx.compose.ui.graphics.Color.White,
    checkedBorderColor = androidx.compose.ui.graphics.Color.Transparent,
    uncheckedTrackColor = Forge.colors.textTertiary.copy(alpha = 0.35f), uncheckedThumbColor = androidx.compose.ui.graphics.Color.White,
    uncheckedBorderColor = androidx.compose.ui.graphics.Color.Transparent,
)

@Composable
internal fun RowDivider() {
    HorizontalDivider(color = Forge.colors.divider.copy(alpha = 0.4f), modifier = Modifier.padding(vertical = 2.dp))
}

/** Minus, the value, plus: the iOS stepper the classic Settings mirror. */
@Composable
internal fun Stepper(value: String, enabled: Boolean = true, onMinus: () -> Unit, onPlus: () -> Unit) {
    val colors = Forge.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        StepButton(Icons.Rounded.Remove, stringResource(R.string.forge_settings_less), enabled, onMinus)
        // An empty value draws the bare pair, as iOS's Stepper does when its label already states the value.
        if (value.isEmpty()) {
            Spacer(Modifier.width(8.dp))
            StepButton(Icons.Rounded.Add, stringResource(R.string.forge_settings_more_step), enabled, onPlus)
            return@Row
        }
        Text(value, style = Forge.type.bodyNumber, color = if (enabled) colors.text else colors.textTertiary,
             textAlign = TextAlign.Center, maxLines = 1, modifier = Modifier.widthIn(min = 72.dp).padding(horizontal = 6.dp))
        StepButton(Icons.Rounded.Add, stringResource(R.string.forge_settings_more_step), enabled, onPlus)
    }
}

@Composable
private fun StepButton(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, enabled: Boolean,
                       onClick: () -> Unit) {
    val colors = Forge.colors
    Box(Modifier.size(36.dp).background(colors.inset, CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = if (enabled) colors.text else colors.textTertiary,
             modifier = Modifier.size(18.dp))
    }
}

/** A segmented pill: one choice of a few, the chosen one raised. */
@Composable
internal fun <T> Segmented(options: List<T>, selected: T, label: @Composable (T) -> String, onSelect: (T) -> Unit) {
    val colors = Forge.colors
    Row(Modifier.background(colors.inset, RoundedCornerShape(10.dp)).padding(2.dp)) {
        options.forEach { option ->
            val chosen = option == selected
            Text(label(option), style = Forge.type.footnote, color = if (chosen) colors.text else colors.textSecondary,
                 maxLines = 1,
                 modifier = Modifier
                     .background(if (chosen) colors.surface else colors.inset, RoundedCornerShape(8.dp))
                     .clickable(role = Role.RadioButton) { onSelect(option) }
                     .padding(horizontal = 10.dp, vertical = 7.dp))
        }
    }
}
