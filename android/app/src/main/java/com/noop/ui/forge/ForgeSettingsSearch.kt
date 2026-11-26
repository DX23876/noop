package com.noop.ui.forge

import androidx.annotation.StringRes
import com.noop.R

/**
 * One searchable section of the Settings, after iOS `SettingsSearchEntry`: the name shown as a result row, the page it
 * lives on and the words a person might type looking for it. Keywords stay English, as on iOS (a reader of another
 * language still finds a section by its own, translated, name).
 */
internal class SettingsSearchEntry(val page: ForgeSettingsPage, @StringRes val titleRes: Int, val keywords: List<String>)

/**
 * The sections of the Settings in screen order, as iOS `SettingsSearchCatalog.entries` lists them. Left out on
 * purpose: Siri & Shortcuts, the Mac dashboard card and Charts (Apple only, or not on Android).
 */
internal val SETTINGS_SEARCH_ENTRIES: List<SettingsSearchEntry> = listOf(
    SettingsSearchEntry(ForgeSettingsPage.Roadmap, R.string.project_page_title,
        listOf("roadmap", "plan", "planned", "what's next", "coming", "issues", "bugs", "known problems", "reported", "fixed",
               "changelog of plans", "project", "wish", "wishes", "suggestion", "suggest", "idea", "feature request", "vote",
               "help build", "donate data", "teach a sport")),
    SettingsSearchEntry(ForgeSettingsPage.Profile, R.string.l10n_settings_screen_profile_ff4fc027,
        listOf("photo", "picture", "avatar", "name", "date of birth", "age", "sex", "height", "weight", "waist",
               "heart-rate zones", "hr zones", "zone bands", "custom zones", "zone 2", "max heart rate", "VO2max",
               "activity level", "calories", "body fat", "body measurements")),
    SettingsSearchEntry(ForgeSettingsPage.Goals, R.string.forge_goals_more_title,
        listOf("goal", "rest days", "step goal", "daily steps", "streak", "badges", "records", "motivation", "week bar",
               "goal notifications")),
    SettingsSearchEntry(ForgeSettingsPage.Strap, R.string.l10n_settings_screen_strap_02b88eeb,
        listOf("bluetooth", "pairing", "connection", "re-scan", "disconnect", "strap log", "strap name", "rename", "sync",
               "keep screen on")),
    SettingsSearchEntry(ForgeSettingsPage.Strap, R.string.health_connect_category_steps,
        listOf("step count", "step-count correction", "steps estimate", "calibration", "too many steps", "WHOOP 4.0 steps")),
    SettingsSearchEntry(ForgeSettingsPage.Strap, R.string.fsp2_hrs_title,
        listOf("broadcast", "heart-rate sensor", "Garmin", "Zwift", "Peloton", "treadmill", "bike computer", "gym")),
    SettingsSearchEntry(ForgeSettingsPage.BatteryRecording, R.string.forge_settings_battery,
        listOf("battery", "power saving", "low power", "strap battery", "low refresh", "continuous HRV", "beat-to-beat",
               "R-R", "overnight only")),
    SettingsSearchEntry(ForgeSettingsPage.StrapActions, R.string.forge_settings_actions,
        listOf("double-tap", "haptics", "buzz", "vibration", "heart-rate ceiling", "haptic coaching", "wear")),
    SettingsSearchEntry(ForgeSettingsPage.Training, R.string.forge_training,
        listOf("strength", "workout", "RPE", "RIR", "set effort", "session rating", "rest timer", "warm-up", "rest-pause",
               "timer sound", "haptics", "vibration", "notification", "keep screen on", "screen awake", "workout view",
               "exercise media", "download media", "equipment", "kilograms", "weight unit", "weight step", "plates",
               "double-tap")),
    SettingsSearchEntry(ForgeSettingsPage.Training, R.string.forge_st_guided,
        listOf("live session", "guarded workout", "heart-rate band", "auto-detect workouts", "workout suggestions")),
    SettingsSearchEntry(ForgeSettingsPage.TodayTrends, R.string.fsp6_ss_today_cards,
        listOf("water", "hydration", "journal", "journal card", "optional trackers")),
    SettingsSearchEntry(ForgeSettingsPage.Notifications, R.string.nav_notifications,
        listOf("live activity", "lock screen", "wrist alerts", "inactivity", "illness", "battery alerts", "sync reminder",
               "strain target", "training load alert", "cycle awareness", "reminders", "alerts")),
    SettingsSearchEntry(ForgeSettingsPage.Coach, R.string.l10n_settings_screen_ai_coach_130c3eab,
        listOf("Svea", "chat", "API key", "provider", "model", "memory")),
    SettingsSearchEntry(ForgeSettingsPage.LanguageUnits, R.string.settings_language,
        listOf("language", "clock", "12-hour", "24-hour", "week start", "Monday", "Sunday")),
    SettingsSearchEntry(ForgeSettingsPage.LanguageUnits, R.string.l10n_settings_screen_units_12748281,
        listOf("measurement system", "metric", "imperial", "distance", "pace", "temperature", "celsius", "fahrenheit",
               "kilograms", "pounds", "skin temperature", "effort scale")),
    SettingsSearchEntry(ForgeSettingsPage.Appearance, R.string.fsp6_ss_style,
        listOf("theme", "dark mode", "light mode", "preset", "accent colour", "app icon", "coloured icons", "tab bar")),
    SettingsSearchEntry(ForgeSettingsPage.Appearance, R.string.forge_settings_background,
        listOf("time-of-day sky", "day-cycle background", "motif", "sky behind cards", "transparent cards",
               "card transparency", "custom photo", "background image")),
    SettingsSearchEntry(ForgeSettingsPage.Appearance, R.string.fsp6_ss_motion,
        listOf("reduce motion", "animation", "motion effect", "coach animation", "tilt", "rings", "classic rings", "living rings")),
    SettingsSearchEntry(ForgeSettingsPage.Calculations, R.string.forge_settings_calculations,
        listOf("day start", "day cycle", "midnight", "HRV window", "deep sleep", "sleep stage method", "wake check", "scoring")),
    SettingsSearchEntry(ForgeSettingsPage.Calculations, R.string.fsp5_repair_title,
        listOf("recalibrate", "reset baseline", "re-learn", "charge baseline", "refresh today", "recalculate", "21 days",
               "reanalysis", "scores stuck")),
    SettingsSearchEntry(ForgeSettingsPage.DataBackup, R.string.forge_backup_section,
        listOf("export", "import", "backup file", "noopbak", "restore", "move to another phone", "sync to a folder",
               "auto-backup")),
    SettingsSearchEntry(ForgeSettingsPage.DataBackup, R.string.fsp6_ss_imports,
        listOf("Health Connect", "data sources", "WHOOP export", "CSV", "Mi Band", "storage", "clean up")),
    SettingsSearchEntry(ForgeSettingsPage.Help, R.string.forge_settings_guides,
        listOf("how NOOP works", "how your scores work", "limitations", "what works", "help")),
    SettingsSearchEntry(ForgeSettingsPage.Help, R.string.nav_test_centre,
        listOf("diagnostics", "bug report", "strap log", "scheduled export", "experimental probes")),
    SettingsSearchEntry(ForgeSettingsPage.Help, R.string.l10n_settings_screen_diagnostics_3af2279f,
        listOf("export raw sensor data", "CSV", "decoded streams", "device info")),
    SettingsSearchEntry(ForgeSettingsPage.Lab, R.string.forge_settings_lab,
        listOf("experimental", "beta", "stress baseline", "training-based VO2max", "AgeLess", "healthspan", "daily rhythm",
               "rhythm age", "CosinorAge", "Oura")),
    SettingsSearchEntry(ForgeSettingsPage.Lab, R.string.fsp6_ss_whoop5,
        listOf("deep-data unlock", "R22", "ECG", "MG", "WHOOP 5", "protocol probes", "frame capture")),
    SettingsSearchEntry(ForgeSettingsPage.About, R.string.l10n_settings_screen_about_6b21fb79,
        listOf("version", "what's new", "update check", "source code", "GitHub", "licence", "acknowledgements", "medical",
               "support", "donate", "Ko-fi")),
)

/** The sections whose own name or keywords contain [query], in screen order, as iOS `SettingsSearchCatalog.matching`. */
internal fun matchingSettingsEntries(query: String, title: (Int) -> String): List<SettingsSearchEntry> =
    SETTINGS_SEARCH_ENTRIES.filter { e ->
        (listOf(title(e.titleRes)) + e.keywords).any { it.contains(query, ignoreCase = true) }
    }
