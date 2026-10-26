package com.noop.ui.forge

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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Contrast
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.BuildConfig
import com.noop.R
import com.noop.analytics.ClockFormatPreference
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

/** The sex choices the profile stores, by tag, with the onboarding's labels. */
private val SEX_CHOICES = listOf("male" to R.string.onboarding_male, "female" to R.string.onboarding_female,
                                 "nonbinary" to R.string.onboarding_other)

private const val SOURCE_URL = "https://github.com/DX23876/noop"

/** The Forge Settings pages, as the iOS hub lists them (`SettingsPage`): title, subtitle, icon and its tile colour. */
enum class ForgeSettingsPage(val titleRes: Int, val subtitleRes: Int, val icon: ImageVector) {
    Profile(R.string.l10n_settings_screen_profile_ff4fc027, R.string.forge_settings_profile_subtitle, Icons.Rounded.AccountCircle),
    LanguageUnits(R.string.forge_settings_language_units, R.string.forge_settings_language_units_subtitle, Icons.Rounded.Language),
    Appearance(R.string.l10n_settings_screen_appearance_41def7a0, R.string.forge_settings_appearance_subtitle, Icons.Rounded.Contrast),
    About(R.string.l10n_settings_screen_about_6b21fb79, R.string.forge_settings_about_subtitle, Icons.Rounded.Info),
}

/** The hub's groups in iOS order (`SettingsHubLayout`), with the pages the Forge app has so far. */
internal val HUB_GROUPS = listOf(
    R.string.forge_settings_group_you to listOf(ForgeSettingsPage.Profile),
    R.string.forge_settings_group_display to listOf(ForgeSettingsPage.LanguageUnits, ForgeSettingsPage.Appearance),
    R.string.forge_settings_group_help to listOf(ForgeSettingsPage.About),
)

/** The tile colour of a page's icon, the iOS system colour `AppleInspiredColors` gives it. */
@Composable
private fun ForgeSettingsPage.tint(): Color {
    val dark = Forge.colors.dark
    val token = when (this) {
        ForgeSettingsPage.Profile -> ForgeTokens.Color.systemBlue
        ForgeSettingsPage.LanguageUnits -> ForgeTokens.Color.systemOrange
        ForgeSettingsPage.Appearance -> ForgeTokens.Color.systemPurple
        ForgeSettingsPage.About -> ForgeTokens.Color.systemGray
    }
    return Color(if (dark) token.dark else token.light)
}

/**
 * Fork (DX23876), Android plan E-3 (D15 lists settings in the first testing build): Forge Settings as the iOS
 * hub has them, groups of pages with an icon tile, title and subtitle, each opening its own page. The pages read
 * and write the same stores the classic Settings use (`ProfileStore`, `AppLanguagePrefs`, `ClockPrefs`,
 * `NoopPrefs`, `UnitPrefs`, `AppearancePrefs`, `UpdateWatch`), so the two never disagree; what the Forge app has
 * no page for yet (heart-rate zones, step calibration, notifications and more) stays in the classic Settings,
 * which [onClassic] opens.
 */
@Composable
fun ForgeSettings(onClose: () -> Unit, onClassic: () -> Unit) {
    var page by rememberSaveable { mutableStateOf<ForgeSettingsPage?>(null) }
    BackHandler(enabled = page != null) { page = null }
    ForgeSceneBackdrop(ForgeBackdrop.Sky) {
        AnimatedContent(
            targetState = page,
            transitionSpec = {
                // A push to a page slides in from the end, back slides out to it, as a navigation stack does.
                val forward = targetState != null
                (slideInHorizontally { w -> if (forward) w else -w / 3 } + fadeIn()) togetherWith
                    (slideOutHorizontally { w -> if (forward) -w / 3 else w } + fadeOut())
            },
        ) { shown ->
            if (shown == null) Hub(onClose, onOpen = { page = it }, onClassic)
            else Page(shown, onBack = { page = null })
        }
    }
}

@Composable
private fun Hub(onClose: () -> Unit, onOpen: (ForgeSettingsPage) -> Unit, onClassic: () -> Unit) {
    SettingsColumn {
        Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.l10n_settings_screen_settings_c7f73bb5), style = Forge.type.title1,
                 color = Forge.sceneInk.text, modifier = Modifier.weight(1f))
            IconButton(onClick = onClose) {
                Icon(Icons.Rounded.Close, stringResource(R.string.forge_cancel), tint = Forge.sceneInk.text)
            }
        }
        HUB_GROUPS.forEach { (titleRes, pages) ->
            SectionHeader(stringResource(titleRes))
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                pages.forEachIndexed { i, p ->
                    HubRow(p.icon, p.tint(), stringResource(p.titleRes), stringResource(p.subtitleRes)) { onOpen(p) }
                    if (i < pages.lastIndex) HubDivider()
                }
            }
        }
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            HubRow(Icons.Rounded.Tune, Color(if (Forge.colors.dark) ForgeTokens.Color.systemGray.dark
                                             else ForgeTokens.Color.systemGray.light),
                   stringResource(R.string.forge_settings_more), stringResource(R.string.forge_settings_more_detail),
                   onClassic)
        }
    }
}

@Composable
private fun Page(page: ForgeSettingsPage, onBack: () -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context) }
    // The stores are plain preferences; one counter re-reads them after a change, as the classic screen does.
    var revision by remember { mutableIntStateOf(0) }
    fun change(block: () -> Unit) { block(); revision++ }
    SettingsColumn {
        Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.forge_settings_back),
                     tint = Forge.sceneInk.text)
            }
            Text(stringResource(page.titleRes), style = Forge.type.title1, color = Forge.sceneInk.text,
                 maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        }
        key(revision) {
            when (page) {
                ForgeSettingsPage.Profile -> ProfileSection(profile, ::change)
                ForgeSettingsPage.LanguageUnits -> LanguageUnitsSection(context, ::change)
                ForgeSettingsPage.Appearance -> AppearanceSection(::change)
                ForgeSettingsPage.About -> AboutSection()
            }
        }
    }
}

/** The scrolling column every Settings screen sits in, clear of the system bars. */
@Composable
private fun SettingsColumn(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())
            .padding(horizontal = ForgeMetrics.screenPadding).widthIn(max = ForgeMetrics.maxContentWidth)
            .navigationBarsPadding().padding(bottom = ForgeMetrics.space4),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap),
        content = content,
    )
}

/** One hub row as iOS draws it (`SettingsHubRow`): icon tile, title over subtitle, chevron. */
@Composable
private fun HubRow(icon: ImageVector, tint: Color, title: String, subtitle: String, onClick: () -> Unit) {
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
            Text(subtitle, style = Forge.type.subhead, color = colors.textSecondary)
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun HubDivider() {
    HorizontalDivider(color = Forge.colors.divider.copy(alpha = 0.5f), modifier = Modifier.padding(start = ForgeMetrics.space6))
}

/**
 * One settings card as iOS draws it (`SettingsSection`): a title over its blurb, then the rows. A page with one
 * card leaves the title out, since the page title already names it.
 */
@Composable
private fun SettingsCard(title: String?, blurb: String?, content: @Composable ColumnScope.() -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = ForgeMetrics.space5) {
        if (title != null) Text(title, style = Forge.type.title2, color = Forge.colors.text)
        if (blurb != null) {
            Text(blurb, style = Forge.type.footnote, color = Forge.colors.textSecondary,
                 modifier = Modifier.padding(top = if (title != null) ForgeMetrics.space1 else 0.dp))
        }
        if (title != null || blurb != null) Spacer(Modifier.height(ForgeMetrics.space3))
        content()
    }
}

@Composable
private fun ProfileSection(profile: ProfileStore, change: (() -> Unit) -> Unit) {
    val context = LocalContext.current
    val imperial = UnitPrefs.system(context) == UnitSystem.IMPERIAL
    SettingsCard(title = null, blurb = stringResource(R.string.forge_settings_profile_detail)) {
        SettingRow(stringResource(R.string.l10n_settings_screen_age_ff9f1ff3)) {
            Stepper("${profile.age}", onMinus = { change { profile.setAge(profile.age - 1) } },
                    onPlus = { change { profile.setAge(profile.age + 1) } })
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_sex_e301dd60)) {
            Segmented(SEX_CHOICES.map { it.first }, profile.sex,
                      label = { tag -> stringResource(SEX_CHOICES.first { it.first == tag }.second) },
                      onSelect = { tag -> change { profile.sex = tag } })
        }
        RowDivider()
        // With "Use weight from Health Connect" on, the synced reading owns the value (classic Settings).
        val fromHealthConnect = profile.useHealthConnectWeight
        SettingRow(stringResource(R.string.l10n_settings_screen_weight_69c0b815)) {
            if (imperial) {
                val lb = UnitFormatter.kgToPounds(profile.weightKg)
                Stepper("%.0f lb".format(lb), enabled = !fromHealthConnect,
                        onMinus = { change { profile.weightKg = (lb - 1) / UnitFormatter.POUNDS_PER_KILOGRAM } },
                        onPlus = { change { profile.weightKg = (lb + 1) / UnitFormatter.POUNDS_PER_KILOGRAM } })
            } else {
                Stepper("%.1f kg".format(profile.weightKg), enabled = !fromHealthConnect,
                        onMinus = { change { profile.weightKg -= 0.5 } }, onPlus = { change { profile.weightKg += 0.5 } })
            }
        }
        if (fromHealthConnect) {
            Text(stringResource(R.string.forge_settings_weight_health_connect), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        }
        RowDivider()
        SettingRow(stringResource(R.string.l10n_settings_screen_height_3f608b49)) {
            if (imperial) {
                val (ft, inch) = UnitFormatter.cmToFeetInches(profile.heightCm)
                val inches = UnitFormatter.cmToInches(profile.heightCm).roundToInt()
                Stepper("$ft′ $inch″",
                        onMinus = { change { profile.heightCm = (inches - 1) * UnitFormatter.CENTIMETERS_PER_INCH } },
                        onPlus = { change { profile.heightCm = (inches + 1) * UnitFormatter.CENTIMETERS_PER_INCH } })
            } else {
                Stepper("%.0f cm".format(profile.heightCm),
                        onMinus = { change { profile.heightCm -= 1 } }, onPlus = { change { profile.heightCm += 1 } })
            }
        }
        RowDivider()
        // Auto is Tanaka's estimate from the age; a step from Auto starts at that estimate, as iOS does.
        val override = profile.hrMaxOverride
        SettingRow(stringResource(R.string.l10n_settings_screen_max_heart_rate_3d4ed858)) {
            Stepper(if (override > 0) "$override bpm" else stringResource(R.string.forge_settings_hr_auto, profile.hrMaxAuto),
                    onMinus = { change { profile.hrMaxOverride = (if (override > 0) override else profile.hrMaxAuto) - 1 } },
                    onPlus = { change { profile.hrMaxOverride = (if (override > 0) override else profile.hrMaxAuto) + 1 } })
        }
        if (override > 0) {
            TextButton(onClick = { change { profile.hrMaxOverride = 0 } }) {
                Text(stringResource(R.string.forge_settings_hr_use_auto), color = Forge.colors.accent)
            }
        }
    }
}

@Composable
private fun LanguageUnitsSection(context: Context, change: (() -> Unit) -> Unit) {
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
private fun AppearanceSection(change: (() -> Unit) -> Unit) {
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
    }
}

@Composable
private fun AboutSection() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var checking by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<UpdateCheck.Result?>(null) }
    var automatic by remember { mutableStateOf(UpdateWatch.isEnabled(context)) }
    SettingsCard(title = null, blurb = null) {
        SettingRow(stringResource(R.string.forge_version, BuildConfig.VERSION_NAME)) {}
        RowDivider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.l10n_settings_screen_check_automatically_7cd229d2), style = Forge.type.body,
                     color = Forge.colors.text)
                Text(stringResource(R.string.l10n_settings_screen_once_a_day_noop_asks_github_5683aad3),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
            Switch(checked = automatic, onCheckedChange = { automatic = it; UpdateWatch.setEnabled(context, it) },
                   colors = SwitchDefaults.colors(checkedTrackColor = Forge.colors.accent))
        }
        RowDivider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(enabled = !checking, onClick = {
                checking = true; result = null
                scope.launch { result = UpdateCheck.check(BuildConfig.VERSION_NAME); checking = false }
            }) {
                Text(stringResource(if (checking) R.string.l10n_settings_screen_checking_820d6004
                                    else R.string.l10n_settings_screen_check_for_updates_736b9062),
                     color = Forge.colors.accent)
            }
            Text(
                when (val r = result) {
                    is UpdateCheck.Result.UpToDate -> stringResource(R.string.l10n_settings_screen_you_re_on_the_latest_r_027a82be, r.version)
                    is UpdateCheck.Result.Available -> stringResource(R.string.forge_settings_update_available, r.version)
                    UpdateCheck.Result.Failed -> stringResource(R.string.l10n_settings_screen_couldn_t_check_try_again_b3c885d9)
                    null -> ""
                },
                style = Forge.type.caption, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f),
            )
        }
        (result as? UpdateCheck.Result.Available)?.let { available ->
            TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(available.url))) }) {
                Text(stringResource(R.string.forge_settings_update_open), color = Forge.colors.accent)
            }
        }
        RowDivider()
        TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SOURCE_URL))) }) {
            Text(stringResource(R.string.forge_settings_source), color = Forge.colors.accent)
        }
    }
}

/** A labelled row: the label on the left, its control on the right. */
@Composable
private fun SettingRow(label: String, control: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = ForgeMetrics.minHitTarget), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.body, color = Forge.colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.weight(1f).padding(end = ForgeMetrics.space2))
        control()
    }
}

@Composable
private fun RowDivider() {
    HorizontalDivider(color = Forge.colors.divider.copy(alpha = 0.4f), modifier = Modifier.padding(vertical = 2.dp))
}

/** Minus, the value, plus: the iOS stepper the classic Settings mirror. */
@Composable
private fun Stepper(value: String, enabled: Boolean = true, onMinus: () -> Unit, onPlus: () -> Unit) {
    val colors = Forge.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        StepButton(Icons.Rounded.Remove, stringResource(R.string.forge_settings_less), enabled, onMinus)
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
private fun <T> Segmented(options: List<T>, selected: T, label: @Composable (T) -> String, onSelect: (T) -> Unit) {
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


private fun Context.hostingActivity(): Activity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
