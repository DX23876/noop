package com.noop.ui.forge

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

// Settings › Language and units, Appearance, Today cards and the background.

@Composable
internal fun LanguageUnitsSection(context: Context, change: (() -> Unit) -> Unit) {
    val language = AppLanguagePrefs.selected(context)
    var picking by remember { mutableStateOf(false) }
    SettingsCard(title = stringResource(R.string.settings_language), blurb = null) {
        SettingRow(stringResource(R.string.settings_language)) {
            Text(if (language == AppLanguage.SYSTEM) stringResource(R.string.settings_language_system) else language.autonym,
                 style = Forge.type.body, color = Forge.colors.accent,
                 modifier = Modifier.clickable(role = Role.Button) { picking = true }.padding(vertical = 8.dp))
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_clock_04f6b3ea)) {
            Segmented(listOf(ClockFormatPreference.SYSTEM, ClockFormatPreference.TWELVE_HOUR,
                             ClockFormatPreference.TWENTY_FOUR_HOUR), ClockPrefs.preference(context),
                      label = {
                          when (it) {
                              ClockFormatPreference.TWELVE_HOUR -> stringResource(R.string.l10n_settings_screen_12_hour_41c18ba0)
                              ClockFormatPreference.TWENTY_FOUR_HOUR -> stringResource(R.string.l10n_settings_screen_24_hour_18e86819)
                              else -> stringResource(R.string.settings_language_system)
                          }
                      },
                      onSelect = { change { ClockPrefs.setPreference(context, it) } })
        }
    }
    SettingsCard(title = stringResource(R.string.l10n_settings_screen_units_12748281),
                 blurb = stringResource(R.string.forge_settings_units_blurb)) {
        SettingRow(stringResource(R.string.units_body_measurements)) {
            Segmented(listOf(UnitSystem.METRIC, UnitSystem.IMPERIAL), UnitPrefs.system(context),
                      label = {
                          stringResource(if (it == UnitSystem.METRIC) R.string.onboarding_metric else R.string.onboarding_imperial)
                      },
                      onSelect = { change { NoopPrefs.setUnitSystem(context, it) } })
        }
        RowDivider()
        SettingRow(stringResource(R.string.units_exercise_distance_pace)) {
            Segmented(listOf(UnitSystem.METRIC, UnitSystem.IMPERIAL), UnitPrefs.distanceSystem(context),
                      label = { stringResource(if (it == UnitSystem.METRIC) R.string.units_kilometres else R.string.units_miles) },
                      onSelect = { change { NoopPrefs.setDistanceUnitSystem(context, it) } })
        }
        RowDivider()
        // Unset follows the body measurements, which is what the first choice says.
        val temperatureRaw = NoopPrefs.of(context).getString(NoopPrefs.KEY_TEMPERATURE_UNIT, null)
            ?.takeIf { raw -> TemperatureUnit.entries.any { it.raw == raw } } ?: ""
        SettingRow(stringResource(R.string.l10n_settings_screen_temperature_0a9062a9)) {
            Segmented(listOf("", TemperatureUnit.CELSIUS.raw, TemperatureUnit.FAHRENHEIT.raw), temperatureRaw,
                      label = {
                          when (it) {
                              TemperatureUnit.CELSIUS.raw -> "°C"
                              TemperatureUnit.FAHRENHEIT.raw -> "°F"
                              else -> stringResource(R.string.units_follow_body)
                          }
                      },
                      onSelect = { change { NoopPrefs.setTemperatureUnit(context, TemperatureUnit.fromRaw(it)) } })
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_skin_temperature_fc103030)) {
            Segmented(listOf(SkinTempDisplay.Kind.ABSOLUTE, SkinTempDisplay.Kind.DEVIATION), UnitPrefs.skinTempPreferred(context),
                      label = {
                          stringResource(if (it == SkinTempDisplay.Kind.ABSOLUTE) R.string.l10n_settings_screen_temperature_0a9062a9
                                         else R.string.skin_temp_vs_baseline)
                      },
                      onSelect = { change { NoopPrefs.setSkinTempDisplay(context, it) } })
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_effort_scale_81afa9ef)) {
            Segmented(listOf(EffortScale.HUNDRED, EffortScale.WHOOP), UnitPrefs.effortScale(context),
                      label = { if (it == EffortScale.HUNDRED) "0–100" else "0–21" },
                      onSelect = { change { UnitPrefs.setEffortScale(context, it) } })
        }
    }
    if (picking) {
        AlertDialog(
            onDismissRequest = { picking = false },
            title = { Text(stringResource(R.string.settings_choose_language)) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    AppLanguage.entries.forEach { option ->
                        Text(if (option == AppLanguage.SYSTEM) stringResource(R.string.settings_language_system) else option.autonym,
                             style = Forge.type.body,
                             color = if (option == language) Forge.colors.accent else Forge.colors.text,
                             modifier = Modifier.fillMaxWidth().clickable(role = Role.Button) {
                                 picking = false
                                 if (option != language) {
                                     // Every string switches at once by recreating the activity, as the classic row does.
                                     AppLanguagePrefs.set(context, option)
                                     context.hostingActivity()?.recreate()
                                 }
                             }.padding(vertical = 12.dp))
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { picking = false }) { Text(stringResource(R.string.forge_cancel)) } },
        )
    }
}

@Composable
internal fun AppearanceSection(change: (() -> Unit) -> Unit) {
    val context = LocalContext.current
    SettingsCard(title = null, blurb = null) {
        SettingRow(stringResource(R.string.l10n_settings_screen_theme_a797e309)) {
            Segmented(listOf(AppearanceMode.SYSTEM, AppearanceMode.LIGHT, AppearanceMode.DARK), AppearancePrefs.mode,
                      label = {
                          when (it) {
                              AppearanceMode.LIGHT -> stringResource(R.string.settings_theme_light)
                              AppearanceMode.DARK -> stringResource(R.string.settings_theme_dark)
                              AppearanceMode.SYSTEM -> stringResource(R.string.settings_language_system)
                          }
                      },
                      onSelect = { change { AppearancePrefs.set(context, it) } })
        }
        RowDivider()
        // The launcher icon swaps manifest aliases through the classic helper; the launcher may take a moment.
        SettingRow(stringResource(R.string.l10n_settings_screen_app_icon_abde7a74)) {
            Segmented(listOf(false, true), NoopPrefs.appIconNavy(context),
                      label = { stringResource(if (it) R.string.forge_settings_icon_blue else R.string.forge_settings_icon_titanium) },
                      onSelect = { navy -> change { setAppIcon(context, navy) } })
        }
        // The new design's colour profiles, as iOS's Design card: colourful by default, Stone, Slate and Sage calm.
        if (ForgeDesign.preview) {
            RowDivider()
            SettingRow(stringResource(R.string.forge_ap_color_profile)) {
                Segmented(ForgeColorProfile.entries.toList(), ForgeColorProfile.current,
                          label = { stringResource(when (it) {
                              ForgeColorProfile.Colorful -> R.string.forge_ap_colorful
                              ForgeColorProfile.Stone -> R.string.forge_ap_stone
                              ForgeColorProfile.Slate -> R.string.forge_ap_slate
                              ForgeColorProfile.Sage -> R.string.forge_ap_sage
                          }) },
                          onSelect = { change { ForgeColorProfile.set(context, it) } })
            }
            // iOS shows the accent choice only for the colourful profile; the calm ones bring their own.
            if (ForgeColorProfile.current == ForgeColorProfile.Colorful) {
                RowDivider()
                SettingRow(stringResource(R.string.forge_ap_accent)) {
                    // A custom colour chosen in the classic settings stays visible as its own choice, so the row never
                    // claims System Blue while the app wears another colour.
                    val accents = listOf("systemBlue", "mint", "whoopBlue") + listOfNotNull("custom".takeIf { ForgeAccent.raw == it })
                    Segmented(accents, ForgeAccent.raw.takeIf { it in accents } ?: "systemBlue",
                              label = { stringResource(when (it) {
                                  "mint" -> R.string.forge_ap_mint
                                  "whoopBlue" -> R.string.forge_ap_whoop_blue
                                  "custom" -> R.string.forge_ap_custom
                                  else -> R.string.forge_ap_system_blue
                              }) },
                              onSelect = { change { ForgeAccent.set(context, it) } })
                }
            }
        }
    }
    BackgroundCard()
    // iOS's Motion card: hold every looping surface still, and choose living or classic score rings.
    SettingsCard(title = stringResource(R.string.forge_ap_motion), blurb = null) {
        var quiet by remember { mutableStateOf(NoopPrefs.quietMotion(context)) }
        ToggleRow(stringResource(R.string.forge_ap_reduce_motion), stringResource(R.string.forge_ap_reduce_motion_note), quiet) { on ->
            quiet = on; change { NoopPrefs.setQuietMotion(context, on) }
        }
        RowDivider()
        SettingRow(stringResource(R.string.forge_ap_score_rings)) {
            Segmented(ScoreRingStyle.entries.toList(), ScoreRingStyle.current,
                      label = { stringResource(if (it == ScoreRingStyle.Classic) R.string.forge_ap_classic else R.string.forge_ap_living) },
                      onSelect = { change { ScoreRingStyle.set(context, it) } })
        }
        Text(stringResource(R.string.forge_ap_rings_note), style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
}

/** The iOS Settings › Dashboard card: which dashboard Today shows, and for Trends its four metric slots. */
@Composable
private fun DashboardStyleSection(change: (() -> Unit) -> Unit) {
    val context = LocalContext.current
    var style by remember { mutableStateOf(DashboardStylePrefs.style(context)) }
    val ids = DashboardStylePrefs.STYLES
    // One list names the styles; the labels come from it, so a reorder cannot label a style wrongly.
    val labels = ids.map { stringResource(DashboardStylePrefs.labelRes(it)) }
    SettingsCard(title = stringResource(R.string.forge_db_style), blurb = null) {
        SettingRow(stringResource(R.string.forge_db_style)) {
            ReportPicker(labels[ids.indexOf(style).coerceAtLeast(0)], labels) { i ->
                change { DashboardStylePrefs.set(context, ids[i]); style = ids[i] }
            }
        }
        if (style == "trends") {
            val slotLabels = listOf(R.string.forge_db_slot1, R.string.forge_db_slot2, R.string.forge_db_slot3, R.string.forge_db_slot4)
            val cards = com.noop.ui.DashboardCard.entries
            val titles = cards.map { stringResource(it.titleRes) }
            val chosen = remember { mutableStateOf(TrendsMetricSlots.slots(context)) }
            TrendsMetricSlots.KEYS.forEachIndexed { i, key ->
                RowDivider()
                SettingRow(stringResource(slotLabels[i])) {
                    ReportPicker(titles[cards.indexOf(chosen.value[i]).coerceAtLeast(0)], titles) { k ->
                        change { NoopPrefs.of(context).edit().putString(key, cards[k].raw).apply()
                                 chosen.value = chosen.value.toMutableList().also { it[i] = cards[k] } }
                    }
                }
            }
        }
    }
}

/**
 * The iOS "Cards on Today" card: water gates the water card, its page and hydration goals; the journal switch gates
 * the journal card. Its Dashboard card is above it.
 */
@Composable
internal fun TodayCardsSection(change: (() -> Unit) -> Unit) {
    val context = LocalContext.current
    SettingsCard(title = stringResource(R.string.forge_settings_today_cards), blurb = null) {
        ToggleRow(stringResource(R.string.forge_settings_water), stringResource(R.string.forge_settings_water_detail),
                  NoopPrefs.hydrationTracking(context)) { on -> change { NoopPrefs.setHydrationTracking(context, on) } }
        RowDivider()
        ToggleRow(stringResource(R.string.forge_settings_journal_card), stringResource(R.string.forge_settings_journal_card_detail),
                  NoopPrefs.journalReminderEnabled(context)) { on -> change { NoopPrefs.setJournalReminderEnabled(context, on) } }
    }
}

/** The iOS Appearance "Background" card: time-of-day sky, sky behind cards and card transparency. */
@Composable
private fun BackgroundCard() {
    val context = LocalContext.current
    val opacityPercent = (CardAppearance.opacity * 100).roundToInt()
    SettingsCard(title = stringResource(R.string.forge_settings_background), blurb = null) {
        ToggleRow(stringResource(R.string.forge_settings_day_sky), stringResource(R.string.forge_settings_day_sky_detail),
                  ForgeBackground.dayCycle) { ForgeBackground.setDayCycle(context, it) }
        if (ForgeBackground.dayCycle) {
            RowDivider()
            ToggleRow(stringResource(R.string.forge_settings_sky_behind_cards),
                      stringResource(R.string.forge_settings_sky_behind_cards_detail),
                      ForgeBackground.behindCards) { ForgeBackground.setBehindCards(context, it) }
        }
        RowDivider()
        // The switch is a shortcut over the same percentage, as on iOS: on starts at 70 % unless already set lower.
        ToggleRow(stringResource(R.string.forge_settings_transparent_cards),
                  stringResource(R.string.forge_settings_transparent_cards_detail), opacityPercent < 100) { on ->
            ForgeBackground.setCardOpacity(context, if (on) (if (opacityPercent >= 100) 70 else opacityPercent) else 100)
        }
        if (opacityPercent < 100) {
            RowDivider()
            SettingRow(stringResource(R.string.forge_settings_card_transparency)) {
                Text(stringResource(R.string.forge_percent, 100 - opacityPercent), style = Forge.type.bodyNumber, color = Forge.colors.accent)
            }
            Slider(value = (100 - opacityPercent).toFloat(), valueRange = 0f..100f,
                   onValueChange = { ForgeBackground.setCardOpacity(context, 100 - it.roundToInt()) },
                   colors = SliderDefaults.colors(thumbColor = Forge.colors.accent, activeTrackColor = Forge.colors.accent))
            Text(stringResource(R.string.forge_settings_card_transparency_detail), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        }
    }
}

private fun Context.hostingActivity(): Activity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
