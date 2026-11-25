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
import androidx.compose.foundation.border
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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import com.noop.ui.AccentColor
import com.noop.ui.AccentPrefs
import com.noop.ui.ChartStyle
import com.noop.ui.ChartStylePrefs
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
        RowDivider()
        // The first day of the week (iOS `TrainingWeekStart`): training, the weekly review and the week strips follow it.
        SettingRow(stringResource(R.string.fsp4_week_start)) {
            Segmented(listOf(false, true), WeekStartPrefs.sundayFirst(context),
                      label = { stringResource(if (it) R.string.fsp4_sunday else R.string.fsp4_monday) },
                      onSelect = { sunday -> change { WeekStartPrefs.set(context, sunday) } })
        }
        Text(stringResource(R.string.fsp4_week_start_note), style = Forge.type.caption, color = Forge.colors.textSecondary)
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

/**
 * iOS's `ThemePreset`: a one-tap bundle of accent, chart colours, sky and card transparency. Nothing is stored; the
 * name shown is the first recipe the live settings match, or Custom. A null [chart] leaves the chart colours alone
 * (Apple Health's own palette has no Android counterpart) and matches whatever they are.
 */
internal enum class ThemePresetChoice(val labelRes: Int, val accent: String, val chart: ChartStyle?, val sky: Boolean, val opacity: Int) {
    Health(R.string.fsp4_preset_health, "systemBlue", null, false, 100),
    Mint(R.string.forge_ap_mint, "mint", ChartStyle.TITANIUM, true, 100),
    Ocean(R.string.fsp4_preset_ocean, "whoopBlue", ChartStyle.TITANIUM, true, 100),
    Classic(R.string.forge_ap_classic, "whoopBlue", ChartStyle.CLASSIC, true, 100),
    Midnight(R.string.fsp4_preset_midnight, "mint", ChartStyle.TITANIUM, false, 100),
    Frosted(R.string.fsp4_preset_frosted, "mint", ChartStyle.TITANIUM, true, 85);

    companion object {
        fun matching(accent: String, chart: ChartStyle, sky: Boolean, opacity: Int): ThemePresetChoice? =
            entries.firstOrNull { it.accent == accent && (it.chart == null || it.chart == chart) && it.sky == sky && it.opacity == opacity }
    }
}

/** A choice from a menu: the current one in the accent, the options under it (iOS's `.pickerStyle(.menu)`). */
@Composable
internal fun <T> MenuPicker(current: String, options: List<T>, label: @Composable (T) -> String, onSelect: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Text(current, style = Forge.type.body, color = Forge.colors.accent,
             modifier = Modifier.clickable(role = Role.Button) { open = true }.padding(vertical = 8.dp))
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { option -> DropdownMenuItem(text = { Text(label(option)) }, onClick = { open = false; onSelect(option) }) }
        }
    }
}

@Composable
internal fun AppearanceSection(change: (() -> Unit) -> Unit) {
    val context = LocalContext.current
    SettingsCard(title = stringResource(R.string.fsw4_style), blurb = stringResource(R.string.fsw4_style_blurb)) {
        // The preset first, as iOS: recipes of accent, chart colours, sky and card transparency, derived from the live
        // settings, so changing any of them below turns the name into Custom.
        val matching = ThemePresetChoice.matching(ForgeAccent.raw, ChartStylePrefs.style, ForgeBackground.dayCycle,
                                                  (CardAppearance.opacity * 100).roundToInt())
        SettingRow(stringResource(R.string.fsp4_preset)) {
            MenuPicker(stringResource(matching?.labelRes ?: R.string.forge_ap_custom), ThemePresetChoice.entries.toList(),
                       label = { stringResource(it.labelRes) },
                       onSelect = { p ->
                           change {
                               ForgeAccent.set(context, p.accent)
                               p.chart?.let { ChartStylePrefs.set(context, it) }
                               ForgeBackground.setDayCycle(context, p.sky)
                               ForgeBackground.setCardOpacity(context, p.opacity)
                           }
                       })
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_theme_a797e309)) {
            val themeLabel: @Composable (AppearanceMode) -> String = {
                when (it) {
                    AppearanceMode.LIGHT -> stringResource(R.string.settings_theme_light)
                    AppearanceMode.DARK -> stringResource(R.string.settings_theme_dark)
                    AppearanceMode.SYSTEM -> stringResource(R.string.fsw4_system)
                }
            }
            MenuPicker(themeLabel(AppearancePrefs.mode), listOf(AppearanceMode.SYSTEM, AppearanceMode.LIGHT, AppearanceMode.DARK),
                       label = themeLabel, onSelect = { change { AppearancePrefs.set(context, it) } })
        }
        // The new design's colour profiles, as iOS's Design card: colourful by default, Stone, Slate and Sage calm.
        if (ForgeDesign.preview) {
            RowDivider()
            SettingRow(stringResource(R.string.forge_ap_color_profile)) {
                val profileLabel: @Composable (ForgeColorProfile) -> String = { stringResource(when (it) {
                    ForgeColorProfile.Colorful -> R.string.forge_ap_colorful
                    ForgeColorProfile.Stone -> R.string.forge_ap_stone
                    ForgeColorProfile.Slate -> R.string.forge_ap_slate
                    ForgeColorProfile.Sage -> R.string.forge_ap_sage
                }) }
                MenuPicker(profileLabel(ForgeColorProfile.current), ForgeColorProfile.entries.toList(), label = profileLabel,
                          onSelect = { profile ->
                              change {
                                  // The profile brings its backdrop along, as on iOS: the sky under Colorful, none under
                                  // the calm ones; the switch stays the wearer's after that.
                                  ForgeColorProfile.set(context, profile)
                                  ForgeBackground.setDayCycle(context, profile == ForgeColorProfile.Colorful)
                              }
                          })
            }
            // iOS shows the accent choice only for the colourful profile; the calm ones bring their own.
            if (ForgeColorProfile.current == ForgeColorProfile.Colorful) {
                RowDivider()
                val accents = listOf("systemBlue", "mint", "whoopBlue", "custom")
                val accentLabel: @Composable (String) -> String = { stringResource(when (it) {
                    "mint" -> R.string.forge_ap_mint
                    "whoopBlue" -> R.string.forge_ap_whoop_blue
                    "custom" -> R.string.forge_ap_custom
                    else -> R.string.forge_ap_system_blue
                }) }
                SettingRow(stringResource(R.string.forge_ap_accent)) {
                    val chosen = ForgeAccent.raw.takeIf { it in accents } ?: "systemBlue"
                    MenuPicker(accentLabel(chosen), accents, label = accentLabel, onSelect = { change { ForgeAccent.set(context, it) } })
                }
                // The colour itself, only while the accent is Custom (iOS shows its colour well then).
                if (ForgeAccent.raw == "custom") {
                    RowDivider()
                    SettingRow(stringResource(R.string.fsp4_custom_colour)) {
                        Box(Modifier.size(28.dp).background(Forge.colors.accent, CircleShape)
                                .border(ForgeMetrics.hairline, Forge.colors.border, CircleShape))
                    }
                    ForgeColorWell(AccentPrefs.customHex) { hex -> change { AccentPrefs.setCustomHex(context, hex) } }
                }
            }
        }
        RowDivider()
        // The launcher icon swaps manifest aliases through the classic helper; the launcher may take a moment.
        SettingRow(stringResource(R.string.l10n_settings_screen_app_icon_abde7a74)) {
            val iconLabel: @Composable (Boolean) -> String = {
                stringResource(if (it) R.string.forge_settings_icon_blue else R.string.forge_settings_icon_titanium)
            }
            MenuPicker(iconLabel(NoopPrefs.appIconNavy(context)), listOf(false, true), label = iconLabel,
                       onSelect = { navy -> change { setAppIcon(context, navy) } })
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
        RowDivider()
        // The coach button's slow pulse (iOS `CoachTilePrefs.breathingKey`); Reduce motion above still holds it still.
        ToggleRow(stringResource(R.string.fsp4_coach_animation), stringResource(R.string.fsp4_coach_animation_note),
                  CoachBreathPrefs.enabled(context)) { on -> change { CoachBreathPrefs.set(context, on) } }
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
        // Today's own surfaces over the day's picture, shown as transparency like the slider above (iOS, new design).
        if (ForgeDesign.preview) {
            RowDivider()
            val todayTransparency = 100 - TodaySurfacePrefs.percent(context)
            SettingRow(stringResource(R.string.fsp4_today_transparency)) {
                Text(stringResource(R.string.forge_percent, todayTransparency), style = Forge.type.bodyNumber, color = Forge.colors.accent)
            }
            Slider(value = todayTransparency.toFloat(), valueRange = 0f..100f, steps = 19,
                   onValueChange = { TodaySurfacePrefs.set(context, 100 - it.roundToInt()) },
                   colors = SliderDefaults.colors(thumbColor = Forge.colors.accent, activeTrackColor = Forge.colors.accent))
            Text(stringResource(R.string.fsp4_today_transparency_note), style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        RowDivider()
        BackgroundPhotoControls()
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
