# Settings parity: iOS Settings against Android Forge Settings

Inventory made 2026-11-25 on branch `feature/forge-settings-night`. Read-only analysis: nothing in the app was changed.
iOS/macOS (SwiftUI) is the reference. Android should match it feature by feature. The porters work from this
file alone, so it names files and composables, never line numbers (the Android Settings files are being split
while this is written).

Related, not repeated here: `COACH-PARITY.md` (the coach settings are already inventoried there, row by row) and
`FORGE-PARITY.md` (the shell and the other tabs).

## Summary

Counts of iOS items by status (section 2; 23 Android-only items are listed separately in section 3):

| Section | SAME | DIFFERENT | MISSING | PLATFORM |
|---|---|---|---|---|
| 2.1 Hub (`ForgeSettingsView`; Android `NewDesignHub` and routing in `FS`) | 8 | 8 | 1 | 1 |
| 2.2 Project | 5 | 0 | 0 | 0 |
| 2.3 Profile | 6 | 6 | 3 | 0 |
| 2.4 Goals | 7 | 1 | 0 | 1 |
| 2.5 Strap | 4 | 7 | 2 | 1 |
| 2.6 Strap Actions | 1 | 3 | 0 | 1 |
| 2.7 Notifications | 1 | 5 | 1 | 2 |
| 2.8 Training | 21 | 3 | 2 | 1 |
| 2.9 Today & Trends | 2 | 0 | 0 | 1 |
| 2.10 AI Coach | 3 | 3 | 1 | 1 |
| 2.11 Siri & Shortcuts | 0 | 0 | 0 | 1 |
| 2.12 Language & Units | 8 | 0 | 1 | 0 |
| 2.13 Appearance | 8 | 2 | 12 | 1 |
| 2.14 Calculations | 4 | 1 | 3 | 0 |
| 2.15 Data & Backup | 5 | 2 | 1 | 2 |
| 2.16 Help & Diagnostics | 4 | 1 | 0 | 2 |
| 2.17 Lab | 4 | 2 | 1 | 1 |
| 2.18 Screens below the pages (compared at screen level only) | 7 | 4 | 1 | 1 |
| 2.19 About | 3 | 4 | 3 | 0 |
| **Total (202 items)** | **101** | **52** | **32** | **17** |

Things worth knowing before starting:

1. The hub that counts is the redesign's `ForgeSettingsView`; Android's `NewDesignHub` already follows it closely. The gaps are
   in the pages, not the hub: Android has no grouped Strap page and no "Devices and data sources" page.
2. Several controls exist on Android only inside the classic cards, reachable only through the Android-only "All settings"
   page (step correction and step estimate, theme Preset, custom accent, custom background photo, Charts, raw sensor CSV).
3. Week start (Monday or Sunday) has no screen on Android, although five Kotlin files read the preference.
4. The core already accepts a manual VO₂max and an activity level; Android never sends them (`CoreShadow.extras`).
5. Android's "Effort: exponential intensity scale" switch has no effect in the core since #2438.
6. The Forge About page has no Ko-fi link, no build stamp, no medical disclaimer and an Acknowledgements page that
   shows exercise-provider credits only, while the fork rule says adopted contributors must be credited in it.
7. Chart-style pickers would write preferences no Forge screen on Android reads (and on iOS only two non-Forge screens read them).
8. Uncommitted edits in the main checkout overlap `CoreCall.swift`, `CoreShadow.kt` and `AppLanguage.kt` (section 5.4).

---

## 0. How to read this document

**Two iOS hubs exist.** The iPhone redesign opens `ForgeSettingsView` (`StrandiOS/Forge/ForgeSettingsView.swift`,
with `ForgeSettingsHubs.swift` for the grouped Strap page, the Devices and data sources page and the "How NOOP
scores" page). Its rows open the same `SettingsPage` content as the classic hub `SettingsHubView`
(`Strand/Screens/SettingsHubView.swift`, order from `SettingsHubLayout`), which is what macOS and the old iPhone design
use. Page content is one set of cards in `Strand/Screens/SettingsView.swift`, routed by `SettingsPageDestination`.
Where the redesign differs from the classic card (the iOS Forge skin hides the waist field, the "Body
measurements" row and the photo row in Profile) the table says so. **The hub that counts for Android is
`ForgeSettingsView`**, because Android's `NewDesignHub` is its twin and the old design is retired on both platforms
(`ForgeDesign.retireTheOldDesign`).

**Status words** (one per iOS item, counted in the summary at the end of section 2):

| Status | Meaning |
|---|---|
| SAME | Android has it, same control, same page, same options; wording may differ by platform noun only |
| DIFFERENT | Android has it, but it differs in the way named in the row: placement, wording, missing option, other control, other order or other grouping |
| MISSING | Not reachable from Android Settings (the row says whether something exists elsewhere on Android) |
| PLATFORM | Apple-only (or macOS-only); not an Android gap. The row names the Android substitute, if any |

Android-only things are not counted as iOS items; they are in section 3 and must not be dropped by anyone porting.

**Path shorthand used in the tables**

| Short | Path |
|---|---|
| `F/` | `android/app/src/main/java/com/noop/ui/forge/` |
| `U/` | `android/app/src/main/java/com/noop/ui/` |
| `C/` | `android/app/src/main/java/com/noop/core/` |
| `FS` | `F/ForgeSettings.kt` (enums `ForgeSettingsPage`, `ForgeSettingsSub`; `ForgeSettings`, `Hub`, `NewDesignHub`, `Page`, `HostedPage`, `SubScreen`) |
| `FSP` / `FSGT` / `FSA` / `FSD` / `FSAB` / `FSC` | `F/ForgeSettingsProfile.kt` (`ProfileSection`) / `F/ForgeSettingsGoalsTraining.kt` (`GoalsSettingsSection`, `TrainingSettingsSection`) / `F/ForgeSettingsAppearance.kt` (`LanguageUnitsSection`, `AppearanceSection`, `TodayCardsSection`, `BackgroundCard`) / `F/ForgeSettingsData.kt` (`CalculationsSection`, `DataBackupSection`, `StepsSourceCard`) / `F/ForgeSettingsAbout.kt` (`HelpSection`, `LabSection`, `AboutSection`) / `F/ForgeSettingsComponents.kt` (`SettingsCard`, `SettingRow`, `ToggleRow`, `LinkRow`, `Stepper`, `Segmented`, `HubRow`) |
| `SSC` | `U/SettingsScreen.kt`: the classic Settings screen, one composable `SettingsScreen(viewModel, cards = …)` that draws the cards of `enum ClassicSettingsCard { General, Strap, Advanced, HealthWellness, TestCentre, Charge, Backup, About }`, plus `ProfileStore` |
| iOS `SV` | `Strand/Screens/SettingsView.swift` (`SettingsPageContent`, one `…Card` property per card) |

**Hosted classic.** A Forge page marked `hosted = true` in `ForgeSettingsPage` (Strap, Battery & Recording, Strap Actions,
Notifications, Coach) does not draw Forge rows; it hosts a classic Android screen inside `Hosted(...)` with a
palette that imitates Forge (`hostedTokens`). `ForgeSettingsSub` entries with `cards = …` host classic cards of `SSC` the
same way. `AllSettings` ("All settings", Android-only) hosts every classic card except Backup.

**Android settings storage.** Two stores. (1) `NoopPrefs` / `ProfileStore` / feature `*Prefs` objects: Android
`SharedPreferences`, read by Kotlin UI. (2) The core's own preferences through `CorePrefs` (`C/CorePrefs.kt`),
which calls the core operations `prefs.read` and `prefs.write`. The core side
(`Packages/NoopCoreJNI/Sources/NoopCore/CorePrefs.swift`) accepts a fixed whitelist of 13 keys with type and range:
`goals.limit.longTerm`, `goals.limit.period`, `training.restWeekdays`, `momentum.stepGoal`, `goals.motivation.enabled`,
`goals.todayInviteDismissed`, `goals.introSeen`, `training.newExerciseSets`, `training.defaultRestSeconds`,
`training.warmupRestSeconds`, `training.weightUnit`, `training.effortScale`, `steps.source`. Any other key is
refused. Profile and Lab values the analysis reads travel to the core in `CoreShadow.extras(...)`
(`C/CoreShadow.kt`) as one JSON object that `CoreAnalysis.applyExtras` decodes.

---

## 1. The iOS settings tree

Order is the order the iPhone shows it. Item-level detail (every row, toggle, picker, stepper, button, text) is
in the per-page tables of section 2; this section is the map.

### 1.1 Redesign hub: `ForgeSettingsView` (opened from the profile photo)

`StrandiOS/Forge/ForgeSettingsView.swift`, struct `ForgeSettingsView`. Navigation title "Settings", Done button.

1. Profile header row: avatar, "Your profile", "Body, heart rate and fitness" → `SettingsPage.profile`.
2. Search row "Search settings and screens" → `ForgeRoute.search` (`ForgeSearchView`).
3. Card without heading: **Project** → `.roadmap`.
4. **You**: Goals.
5. **Strap and devices**: Strap (→ `ForgeStrapSettingsView`, grouped page), Devices and data sources (→ `ForgeDevicesSourcesView`).
6. **Alerts**: Alerts and reminders → `.notifications`.
7. **App**: Appearance, Language & Units, Today & Trends, Training, AI Coach, Siri & Shortcuts.
8. **Data and help**: Data & Backup, Calculations, How NOOP scores (→ `ForgeHowScoresView`), Help & Diagnostics.
9. Card without heading: Lab, About.

### 1.2 Classic hub: `SettingsHubView` / `SettingsHubLayout` (`SettingsHubGroup`, `SettingsHubRow`)

Search field "Search settings" (`SettingsSearchCatalog`, 31 section entries, English keywords) above the groups.
Card without heading: Project. Then **You** (Profile, Goals); **Strap & Devices** (Strap, Battery & Recording, Strap Actions);
**Training & Everyday** (Training, Today & Trends, Notifications, AI Coach, Siri & Shortcuts); **Display** (Language & Units,
Appearance); **Data** (Calculations, Data & Backup); **Help** (Help & Diagnostics, Lab, About). `SettingsPage` order and
subtitles are in `Strand/Screens/SettingsSearchCatalog.swift` (`enum SettingsPage`).

### 1.3 Pages and what each is built from

| Page (`SettingsPage`) | Screen / view | Source file | Cards or sections in order |
|---|---|---|---|
| Project (`.roadmap`) | `ProjectHubView` | `Strand/Screens/ProjectPages.swift` | cards Roadmap, Problems, Wishes, Help build it |
| Profile | `SettingsView(initialPage: .profile)`; Forge skin head `forgeProfileHead` | `SV` `profileCard` | one card |
| Goals | `GoalsSettingsView` | `Strand/Screens/Goals/GoalsSupportViews.swift` | How many goals, My rest days, Daily step goal, Notifications, Motivation, Goal invitation |
| Strap | `SettingsView(.strap)` | `SV` | `strapCard`, `stepsCard`, `heartRateSharingCard` |
| Battery & Recording | `PowerSavingView` | `Strand/Screens/PowerSavingView.swift` | `ContinuousHrvSettingsCard` (own file), Power saving card |
| Strap Actions | `AutomationsView(scope: .strapActions)` | `Strand/Screens/AutomationsView.swift` | Double-tap, Haptics, Wear & presence, Haptic coaching |
| Training | `SettingsView(.training)` | `SV` | `trainingCard`, `guidedTrainingCard` |
| Today & Trends | `SettingsView(.todayTrends)` | `SV` | `todayCardsCard` (iPhone); macOS adds `todayLayoutCard` |
| Notifications | `AutomationsView(scope: .notifications)` | `AutomationsView.swift`, `LiveNotificationSettingsCard.swift` (iOS) | Live notifications, Wrist alerts, Inactivity, Illness, Health insights, Battery alerts, Sync reminder (iOS), Strain target, Training load alert |
| AI Coach | `CoachSettingsView(usesHostNavigation: true)` | `Strand/Screens/CoachSettingsView.swift` | unconfigured: Enable switch, setup card; configured: hub of 5 subpages (see `COACH-PARITY.md`) |
| Siri & Shortcuts | `SiriShortcutsSettingsView` | `StrandiOS/App/SiriShortcutsSettingsView.swift` | iOS only |
| Language & Units | `SettingsView(.languageUnits)` | `SV` | `languageCard`, `unitsCard` |
| Appearance | `SettingsView(.appearance)` | `SV` | `designCard` ("Style"), `backgroundCard`, `chartsCard`, `motionCard` |
| Calculations | `SettingsView(.calculations)` | `SV` | `calculationCard`, `AnalysisMaintenanceSettingsCard` ("If scores look wrong") |
| Data & Backup | `SettingsView(.dataBackup)` | `SV` | `backupCard`, `dataConnectionsCard` |
| Help & Diagnostics | `SettingsView(.help)` | `SV` | `guidesCard`, `testCentreCard`, `rawSensorDiagnosticsCard`, (iOS) `deviceInfoCard` |
| Lab | `SettingsView(.lab)` | `SV` | `labCard`, Oura card (Oura only), `fiveMGCard` (5/MG controls only) |
| About | `SettingsView(.about)` | `SV` | `aboutCard` |

### 1.4 Subpages (`enum SettingsSubpage`, `SettingsSubpage.swift`, 13 routes) and sheets (`SettingsSheet`)

| Route | View | Opened from | Android counterpart |
|---|---|---|---|
| `.bodyMeasurements` | `BodyView` | Profile (classic skin only) | none in Settings; Body is the Health tab (`F/ForgeBody.kt`) |
| `.exerciseMedia` | `ExerciseMediaManagementView` | Training | `ForgeSettingsSub.ExerciseMedia` → `ForgeExerciseMediaSettings` |
| `.equipment` | `TrainingEquipmentSettingsView` (private in `SV`) | Training | none in Settings (an equipment dialog sits in `F/ForgeExerciseLibrary.kt`) |
| `.testCentre` | `TestCentreView` | Strap, Help, Project › Problems | `ForgeSettingsSub.TestCentre` → `U/TestCentreScreen.kt` |
| `.dashboard(String)` | `DashboardLayoutEditor` | Today & Trends (macOS) | PLATFORM |
| `.backupSync` | `BackupSyncView` | Data & Backup | `ForgeSettingsSub.BackupSync` → `U/BackupSyncScreen.kt` |
| `.appleWatchData` | `AppleWatchAboutView` | Help | PLATFORM |
| `.storage` | `StorageView` | Data & Backup | none |
| `.heartRateSharing` | `HeartRateSharingView` | Strap | `U/DataSourcesScreen.kt` ("Broadcast HR from this phone") and `SSC` Advanced card |
| `.appleHealth` | `AppleHealthView` | Data & Backup | PLATFORM (Android: Health Connect, `U/DataSourcesScreen.kt`) |
| `.dataSources` | `DataSourcesView` | Data & Backup | `ForgeSettingsSub.DataSources` → `U/DataSourcesScreen.kt` |
| `.shortcutsExport` | `ShortcutExportSettingsView` | Data & Backup (iOS) | PLATFORM |
| `.noopLimitations` | `NoopLimitationsView` | Help | `ForgeSettingsSub.Limitations` → `U/NoopLimitationsScreen.kt` |

Sheets: `whatsNew` (`WhatsNewView`), `scoringGuide` (`ScoringGuideView`), `acknowledgements` (`AcknowledgementsView`),
`howNoopWorks` (`HowNoopWorksView`), `appleWatchSetup` (`AppleWatchSetupView`), `heartRateZones` (`HRZoneEditorSheet`,
`HRZoneEditorView.swift`), `stepCalibration` (`StepsCalibrationSheet`), `diagnostics` (`DiagnosticsSheet`, iOS).
Pushes of the redesign (`ForgeSettingsRoute`): `.scoringGuide` (`ForgeHowScoresView`), `.strap`, `.devicesSources`, `.allFeatures`.

iOS-only or macOS-only (so never an Android gap): Siri & Shortcuts, Shortcuts Export, Apple Health, Apple Watch data and
setup, Live notifications (Lock Screen, Dynamic Island), Sync reminder, "Keep screen on while syncing", Hide tab bar,
Swipe between tabs, Week bar above the tab bar, Motion effect (phone tilt) if Android keeps no tilt control, the
"This iPhone" card, macOS Dashboard style, macOS `NotificationSettingsView` (per-Mac-app wrist alerts), lock-the-Mac
actions.

---

## 2. Item by item: iOS item, Android counterpart, status

Columns: ID, the iOS item (control and what it does), the Android counterpart (file and composable), status, then
what differs and, where it matters, whether Android can do it with the code it has. "Core" means shared logic in
`Packages/` reached through `NoopCoreJNI` (`CoreShadow.kt`, the `Core*.kt` objects, the generated `CoreWhoopDao`).
Kotlin may only add presentation, Bluetooth transport and Android services (`docs/fork/AGENT_RULES.md`).

### 2.1 Hub (`ForgeSettingsView`; Android `NewDesignHub` and routing in `FS`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| H-01 | Large title "Settings", Done button | `FS` `NewDesignHub` header ("Settings", Done) | SAME | |
| H-02 | Profile header row: avatar 64, "Your profile", "Body, heart rate and fitness" → Profile | `FS` `NewDesignHub` first row (`com.noop.ui.ProfileAvatar`, `forge_set_your_profile`) | SAME | |
| H-03 | Search row "Search settings and screens" → the redesign's search | `FS` `NewDesignHub`, row `forge_set_search`, only when the caller passes `onSearch`; it opens the More page with search focused | DIFFERENT | No Settings search of its own; the search that exists is the More index (`F/ForgeMoreIndex.kt`). Android's page words (`SETTINGS_SEARCH_WORDS` in `FS`) are page-level (17 pages); iOS indexes 31 sections (`SettingsSearchCatalog.entries`: Steps, Heart rate sharing, Guided training, Dashboard, Today cards, Language, Units, Style, Background, Charts, Motion, If scores look wrong, Backup, Guides, Test Centre, Diagnostics, Lab, WHOOP 5/MG, About). UI only; no core. |
| H-04 | Card without heading: Project | `FS` `NewDesignHub` `group(null, Roadmap)` | SAME | |
| H-05 | Group "You": Goals | `FS` group `forge_settings_group_you` | SAME | |
| H-06 | Group "Strap and devices", row "Strap" → grouped Strap page (`ForgeStrapSettingsView`: device row, Connection steps and sharing, Recording and battery, Double-tap and buzz, Devices) | `FS` group `forge_set_strap_devices` with three flat rows Strap, Battery & Recording, Strap Actions | DIFFERENT | No grouped Strap page and no device status row (`MoreDeviceRow`) at its head. Android's Strap row opens the hosted classic Strap card directly. See S-01 to S-05. |
| H-07 | Row "Devices and data sources" → `ForgeDevicesSourcesView` (Devices, Data sources, Apple Health, Mi Band, "Values by source", "Steps from" picker) | `FS` `NewDesignHub` row `forge_set_devices_sources` → `ForgeSettingsSub.DataSources` | DIFFERENT | Android opens the Data Sources screen. The iOS page is a small index; its parts exist on Android in other places: Devices (`U/DevicesScreen.kt` via the More page), Data sources (`U/DataSourcesScreen.kt`, includes Health Connect and Mi Band), Values by source (`U/FusedRecordScreen.kt`), Steps from (`FSD` `StepsSourceCard`, on Data & Backup). Port = new Forge page `ForgeDevicesSourcesPage` that links them. UI only. |
| H-08 | Group "Alerts", row "Alerts and reminders" (subtitle "Lock Screen, wrist alerts and reminders") | `FS` group `forge_set_alerts`, row is the Notifications page (title "Notifications", subtitle "Wrist alerts, calls and daily reports") | DIFFERENT | Wording of title and subtitle. The content differs too, see section 2.7. |
| H-09 | Group "App": Appearance, Language & Units, Today & Trends, Training, AI Coach, Siri & Shortcuts | `FS` group `forge_set_app` (same order, no Siri) | SAME | Siri is H-10. Android title is "Language & units" (lower case u). |
| H-10 | Row Siri & Shortcuts | none | PLATFORM | Apple only. Android has no substitute row (the app-shortcut / Quick-actions work is in `F/ForgeQuickActions.kt`, not a settings page). |
| H-11 | Group "Data and help": Data & Backup, Calculations, How NOOP scores, Help & Diagnostics | `FS` group `forge_set_data_help` (same four rows) | SAME | |
| H-12 | Card without heading: Lab, About | `FS` `group(null, Lab, About, All settings)` | SAME | The extra "All settings" row is Android-only (section 3, A-01). |
| H-13 | "How NOOP scores" page: segmented "Explained" / "Your model" → `ScoringGuideView` / `IntelligenceView` | `FS` row `forge_set_how_scores` → `ForgeSettingsSub.ScoringGuide` → `ScoringGuideScreen` | DIFFERENT | "Your model" part is missing from this page. The screen exists on Android (`U/IntelligenceScreen.kt`) and is reachable elsewhere. UI only. |
| H-14 | Page icon tints: three system colours (green, orange, indigo) per `ForgeSettingsView.tint` | `FS` `ForgeSettingsPage.tint()`: blue, orange, green, yellow, purple, indigo, teal, cyan, grey | DIFFERENT | iOS comment: "three system colours so no area shouts louder". UI only. |
| H-15 | Every page opens with `SettingsPageBanner`: tinted card with the page picture (`CoachPicture`) and the page subtitle | `FS` `PageTitle(...)` only (back arrow and title); no picture, subtitle shown only on hosted pages | DIFFERENT | UI only. iOS Profile has its own head instead of the banner (PRO-01). |
| H-16 | Page subtitles (`SettingsPage.subtitle`) | `ForgeSettingsPage.subtitleRes` | DIFFERENT | Wording differs on Strap ("Connection, steps and heart rate sharing" / "Connection, background and strap log"), Battery & Recording ("Power saving and continuous HRV" / "Power saving when the battery runs low"), Strap Actions ("Double-tap, buzzes and heart-rate alerts" / "Double-tap, buzzes and reminders"), Notifications, AI Coach ("Provider, model and memory" / "Provider and model"), Language ("Language, clock, week start and units" / "Language, clock and units"), Appearance ("Theme, background, charts and motion" / "Theme, background and app icon"), Data & Backup ("Backup, Apple Health, imports and storage" / "Backup, imports and Health Connect"), Calculations. Change the Android strings when the page content is brought level (all nine locales). |
| H-17 | Classic hub `SettingsHubView` with search and seven groups (Project card, You, Strap & Devices, Training & Everyday, Display, Data, Help) | `FS` `Hub` (non-preview) with `HUB_GROUPS`, same seven groups, no search field, no Siri | SAME | Used only while `ForgeDesign.preview` is false (the switch is gone from Lab, so in practice dead); keep it compiling, do not extend it. |
| H-18 | Results of the hub search: pages listed with the matching section titles as caption | none | MISSING | Part of H-03. |

### 2.2 Project (iOS `ProjectHubView`; Android `FS` `Page` → `ProjectHubSection`, `F/ForgeRoadmap.kt`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| PJ-01 | Hub: Roadmap, Problems, Wishes, Help build it (cards with scene picture, line, count) | `ProjectHubSection` (`ProjectHubCard` x4) | SAME | Android adds `ProjectSharingCard` (A-20). |
| PJ-02 | Roadmap page (`RoadmapView`) | `ForgeSettingsSub.ProjectRoadmap` → `RoadmapPlanSection` | SAME | Content comes from the core (`C/` `CoreProject`). |
| PJ-03 | Problems: report a problem (with code, optional log), "Build a log myself" → Test Centre, issue tracker link, reported list | `ForgeSettingsSub.ProjectProblems` → `ProblemsSection` | SAME | |
| PJ-04 | Wishes: text field + Send, published list | `ForgeSettingsSub.ProjectWishes` → `WishesSection` | SAME | |
| PJ-05 | Help build it → `RawDonationView` | `ForgeSettingsSub.RawDonation` → `RawDonationSection` (`F/ForgeRawDonation.kt`) | SAME | Also linked from the Training page on Android (TRA-24). |

### 2.3 Profile (iOS `SV` `profileCard` + Forge `forgeProfileHead`; Android `FSP` `ProfileSection`, state in `ProfileStore` inside `SSC`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| PRO-01 | Forge head: avatar 104 with camera badge (tap opens the photo picker), one line "N years · H cm · W kg" | `ProfileSection`: avatar 56, "Change photo" button, Remove | SAME | Closed by package 1: `ProfileHead` in `FSP` draws the 104 dp avatar with the camera badge (tap changes the photo) and the "N years · H cm · W kg" line. Android keeps its Remove-photo button under it (A-02, A-03 stay). Was: Placement and look. The iOS Forge head has no remove action (the classic `profilePhotoRow` has a trash button while editing); Android keeps Remove (keep it). Summary line missing. UI only. |
| PRO-02 | Card header action Edit / Done (`profileEditing`; fields read-only until Edit) | `ProfileSection` TextButton Edit / Done | SAME | |
| PRO-03 | Blurb "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate." | `SettingsCard(blurb = forge_settings_profile_detail)` | SAME | Closed by package 1: iOS wording (`fsp1_profile_blurb`). Was: Wording ("These set your heart-rate zones, energy estimates and baselines…"). |
| PRO-04 | Date of birth: age and date picker (`ProfileStore.dateOfBirthRange`) | `ProfileSection` birthday row, Material date dialog | SAME | |
| PRO-05 | Sex: Male / Female / Non-binary (menu) | `ProfileSection` dropdown over `SEX_CHOICES` (`onboarding_male/female/other`) | SAME | Closed by package 1: the third choice now reads "Non-binary" (`fsp1_sex_nonbinary`). Was: Android labels the third "Other" (string `onboarding_other`) where iOS says "Non-binary". Wording. |
| PRO-06 | Body-composition formula (shown for non-binary only): Not set / Male equation / Female equation, with footnote. Field `ProfileStore.bodyFormulaSex` | none | SAME | Closed by package 1: `ProfileStore.bodyFormulaSex`, the menu and its footnote under Sex (non-binary only). No core change was needed: `body.snapshot` already takes `equation`; `CoreBody.snapshot` now sends `ProfileStore.bodyEquation` (the sex, or the profile's own answer). The Today cycle audience on iOS also reads this field; Android's cycle gating (`HealthScreen`, "female/nonbinary default show") is unchanged and is not part of this row. Was: New `ProfileStore` field + UI. The body-fat estimate that reads it is not in the core call `body.snapshot` (no sex argument in `CoreBody.swift`): find where Android computes the Navy body-fat estimate (`F/ForgeBody.kt`); if Kotlin does, that is logic outside the core and the fix belongs in the core with a `bodyFormulaSex` argument. |
| PRO-07 | Weight: stepper, kg step 0.5 range 30 to 250, or lb step 1 range 66 to 551 | `ProfileSection` `ProfileStepper` | SAME | Checked by package 1: `ProfileStore.weightKg` clamps to 30 to 250 kg (66 to 551 lb through the stepper), so the clamp question is closed. Was: Check the Android clamps: the Kotlin stepper adds or subtracts without the 30 to 250 kg range. |
| PRO-08 | Height: cm step 1 (120 to 230) or whole inches (47 to 91) shown as feet and inches | `ProfileSection` | SAME | Checked by package 1: `ProfileStore.heightCm` clamps to 120 to 230 cm (47 to 91 in). Was: Same clamp check. |
| PRO-09 | Waist (optional): 0 = unset; cm 60 to 160 or inches; note on VO₂max. The Forge skin hides this row (the waist is read from the Body page) | `ProfileSection` waist row with the two footnotes | SAME (written exception) | Exception, decided by package 1: Android keeps the waist field. The iOS Forge skin dropped it because the estimate reads the waist from the Body page; Android sends `waistCm` from here to the core (`CoreShadow.extras`) and has no other place to enter it. Rule "no feature dropped"; remove only with the owner's word. Was: The redesign dropped the field on iOS. Android keeps it. Do not delete without the owner's word (rule: no feature dropped). Android sends `waistCm` to the core in `CoreShadow.extras`. |
| PRO-10 | "Body measurements…" row → `BodyView` (classic skin only; the Forge skin has none) | none | SAME | Absent on both in the redesign. |
| PRO-11 | Max heart rate: stepper 120 to 230, "Auto" until set, caption of the source (Manual override / Measured in your workouts, confirmed date / Estimated from your age / Automatic) | `ProfileSection`: stepper, "Auto (n bpm)", "Use auto" button | SAME | Closed by package 1: the number is always shown (muted while automatic) with the iOS caption (Manual override / Measured in your workouts, confirmed <date> / Estimated from your age / Automatic); a step starts from the value on screen and below 120 returns to automatic. New core operation `profile.maxHeartRate` (`CoreProfile.swift`) resolves it with `MaxHeartRate`, including the level the daily pass measured. Kotlin keeps the answer in `ProfileStore.hrMaxAuto` (refreshed off the main thread in `CoreShadow.extras` and when the page opens), so every Android reader of `hrMax` now agrees with the pass: the age formula is Gellish, no longer Tanaka. The measured level lives in the core's process memory until the next pass after a restart, as on iOS before its first pass. The classic General card behind All settings (package 2's file) still prints "(Tanaka)" in its own literal beside the same number. Was: Source caption missing, including the measured-max source (`ProfileStore.measuredMaxHeartRate`). The measured max is app-side on iOS; check whether the core exposes it before adding the caption. |
| PRO-12 | VO₂max: stepper 10 to 90 step 0.5, "Auto" when unset, "Entered <date>" caption, BMI > 40 warning ("Estimated from a formula that is not validated above a BMI of 40…") | none | SAME | Closed by package 1: `ProfileStore.vo2maxManual` (with day and weight), the stepper (10 to 90, first step from Auto lands at 25, below 10 clears), the "Entered <date>" line and the BMI warning (`profile.vo2Hint` in the core, `PeakMETResolver.measurementAdvised`). Sent to the core in `CoreShadow.extras` and in `withGoalProfile`. Analysis migration required: no (decided by the lead: a wearer input the next daily pass picks up). Backup keys added to the Kotlin whitelist. Was: The core already accepts it: `CoreAnalysis.applyExtras` reads `manualVO2max`, `manualVO2maxDay`, `manualVO2maxWeightKg`. Android never sends them (`CoreShadow.extras` lists no such key). Work: `ProfileStore` fields + UI + three `put(...)` lines in `CoreShadow.extras`. The BMI warning rule is `PeakMETResolver.measurementAdvised` (StrandCore): it needs a small core operation or a Kotlin copy; prefer the core. |
| PRO-13 | Activity level: Auto / Level 1 to 5, footnote on how calories scale to aerobic capacity | none | SAME | Closed by package 1: `ProfileStore.activityLevelOverride` (Auto, Level 1 to 5) with the iOS footnote, sent as `activityLevelOverride`. Reconciled with `energy.activityLevel` (`CoreEnergyPlan.kt`): that key is the Energy Plan's own activity choice (light, moderate, …, `EnergyPlanStore.activityLevelKey` on iOS too), a different fact from the Jurca category the energy model scales workouts with (`profile.activityLevelOverride` on iOS). Both exist on iOS as two keys, so Android keeps two, each with one store. Was: Core accepts `activityLevelOverride` (comment says 1 to 7; iOS menu offers 1 to 5) in `applyExtras`; not sent. Same work as PRO-12. `C/CoreEnergyPlan.kt` has an Android-only key `energy.activityLevel`: reconcile with it before adding another. |
| PRO-14 | Heart-rate zones row → `HRZoneEditorSheet`: mode Standard / Beats, five start points (steppers), "Use the standard bands", explainers, summary text on the row ("Standard bands" / "Custom · 120/135/…") | `ProfileSection` second card "Custom HR zones": switch plus five bpm steppers | SAME | Closed by package 1: row with the summary ("Standard bands" / "Custom · …") opens the new page `ForgeSettingsHrZones.kt` (`ForgeSettingsSub.HrZones`): Standard / % of max / Beats, five steppers over the bands preview, explainers, Use the standard bands, Save disabled while the draft is not legal. The rules (seeding, notch, legality) are the core operation `profile.zones` (`HRZones`). `ProfileStore` keeps the mode and both bound sets; the old one-key bpm set reads as Beats. Percent-mode bounds reach the Kotlin readers exactly (`hrZoneLowerBounds`), three readers switched from the rounded list. The classic General card's zone switch and steppers (All settings) keep working on the Beats mode. Was: Android has beats mode only, no percent-of-max mode, no explainer, no summary row. Zone math is `HRZones` in StrandAnalytics (pure); check whether Android computes bands in Kotlin. UI plus `ProfileStore` fields (`hrZoneConfig`). |
| PRO-15 | Steps controls (Step correction, Step estimate) are on the iOS Strap page, see S-10, S-11 | `SSC` General card (Profile card) only | SAME (closes with package 2) | Package 1 checked: iOS shows Step correction and Step estimate on the Strap page (S-10, S-11), not on Profile, and the Forge Profile page has no steps row on Android either. Nothing to add here; the rows move with package 2. Was: Android's Forge Profile page lacks them; they live in the classic General card, reachable only through "All settings". See S-10. |

### 2.4 Goals (iOS `GoalsSettingsView`; Android `FSGT` `GoalsSettingsSection`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| GOA-01 | How many goals: stepper "Long-term goals: up to N" (1 to 10), stepper "Weekly and monthly goals: up to N" (1 to 12), note | `GoalsSettingsSection` (core prefs `goals.limit.*`) | SAME | |
| GOA-02 | My rest days: seven weekday chips (order follows the week start) + note | `GoalsSettingsSection` `RestDaysPicker` (core `training.restWeekdays`) | SAME | Chip order follows `training.weekStartsOn`, which Android cannot set (LU-03). |
| GOA-03 | Daily step goal: stepper 0 to 30000 step 500, "Not set" | `GoalsSettingsSection` (core `momentum.stepGoal`) | SAME | |
| GOA-04 | Notifications: four toggles (A daily goal reached, A streak in danger in the evening, A new badge, A long-term milestone reached) plus three period toggles (Start of the week, Mid-week when a goal is slipping, Weekly and monthly review); footnote | `F/ForgeGoals.kt` `GoalNotificationsCard` (four kinds, `GoalNoticeNotifier`) | SAME | Closed by package 1: the three weekly-goal switches (Start of the week, Mid-week when a goal is slipping, Weekly and monthly review) under the four, off by default. The decision (which notice, when, what it says) moved out of the Apple-only `GoalNotifier` into the shared `PeriodGoalNoticePlan`, which the iOS scheduler now calls and `goals.notices` returns as `periodNotices`; Android sets one `AlarmManager` alarm per notice (`GoalNoticeNotifier.schedulePeriod`) and drops it when the switch goes off. Unit-tested in the core; alarm delivery not yet seen on a phone. Was: The three period-goal kinds (`GoalPrefs.NotificationKind`) are missing. They are stored as `goals.notify.weekStart`, `goals.notify.midWeek`, `goals.notify.review` in `GoalPreferences.standard` on iOS and are not in the core whitelist. Needs: the core decision (which notice, when) is in `PeriodGoal.swift` / goal notice planning (core calls `goals.notices` exist); the scheduling worker is Kotlin. Check `CoreGoalNotices.swift` before writing anything. |
| GOA-05 | Motivation: switch "Badges, streaks and records" + note | `GoalsSettingsSection` (core `goals.motivation.enabled`) | SAME | |
| GOA-06 | Streak readout "N days in a row", "Longest: N days" | `GoalsSettingsSection` (`viewModel.streaks`) | SAME | |
| GOA-07 | Goal invitation on Today: switch | `GoalsSettingsSection` (`goals.todayInviteDismissed`) | SAME | |
| GOA-08 | Week bar above the tab bar (iOS 26.1) | none | PLATFORM | iOS tab bar feature. |
| GOA-09 | "Show the explainer again" button | `GoalsSettingsSection` `LinkRow` (`goals.introSeen`) | SAME | |

### 2.5 Strap (iOS `SV` `strapCard`, `stepsCard`, `heartRateSharingCard`, `PowerSavingView`, `ForgeStrapSettingsView`; Android hosted `SettingsScreen(cards = {Strap})`, `U/PowerSavingScreen.kt`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| S-01 | Grouped Strap page (`ForgeStrapSettingsView`): device row, "Connection, steps and sharing", "Recording and battery", "Double-tap and buzz", Devices | none (H-06) | MISSING | New Forge page in a new file; rows link to the three existing pages. |
| S-02 | Status pill (connection label) and battery pill ("Battery 80% · Charging") | `SSC` Strap card: status and battery pills | SAME | |
| S-03 | Status detail sentence (paired and sending / not fully paired / connected, finishing handshake / previously paired / none) | `SSC` Strap card (`strapStatusTitle`, pairing hint text) | DIFFERENT | Verify the five sentences exist; iOS `strapStatusDetail`. Presentation only. |
| S-04 | Buttons Re-scan, Disconnect (disabled when not connected and not bonded) | `SSC` Strap card `NoopButton` x2 | SAME | |
| S-05 | "Connection diagnostics" row → Test Centre | none in the Strap card | MISSING | Test Centre is reachable from Help. One `LinkRow` to `ForgeSettingsSub.TestCentre`. |
| S-06 | Strap name: current name, field "New strap name", Rename, status line, note; WHOOP 4.0 only, connected only | `SSC` Strap card rename (4.0), plus an experimental 5/MG rename | SAME | Android adds a 5/MG experimental rename and "Check current name (read-only)" (A-06). |
| S-07 | "Keep screen on while syncing" switch | none | PLATFORM | iOS only. Android substitute: the foreground service and "Keep connected in the background" (A-04). |
| S-08 | Continuous HRV (own page: Battery & Recording): switch + "Nights only" switch + note | `SSC` Strap card (switches "Continuous HRV capture", "Overnight only") | DIFFERENT | Placement: Android has it in the Strap card, iOS in Battery & Recording. Also a second control for the HRV window sits in the same Android card (CAL-02). |
| S-09 | Heart rate sharing → `HeartRateSharingView`: phone broadcaster switch (shares only while that screen is open) with live status; "Via strap" switch (5/MG only) with status, "Stop sharing on the strap" button | `U/DataSourcesScreen.kt` card "Broadcast HR from this phone"; `SSC` Advanced card switch "Broadcast strap HR (Garmin/ANT)" | DIFFERENT | Placement, and the strap-side status readout and the "Stop sharing on the strap" button are missing. Android's phone broadcaster is `com.noop.ble.HrBroadcaster` (Kotlin BLE, needs a phone and a receiver to test). |
| S-10 | Step correction: value and stepper (`stepTicksPerStep`, 1.0 default), note "set it to 10.0" | `SSC` General card (Profile card) `SettingsFormRow("Step calibration")` | DIFFERENT | Android has it, but not on the Forge Strap page; only via All settings. Value already goes to the core in `extras` (`stepTicksPerStep`). Move or link. UI only. |
| S-11 | Step estimate row (summary "Manual" / "Auto · High confidence" / "Not calibrated") → `StepsCalibrationSheet` | `ForgeSettingsSub.StepsCalibration` → `U/StepsCalibrationScreen.kt`; row in `SSC` General card | DIFFERENT | Same as S-10: the screen exists, the Forge entry does not. |
| S-12 | Battery & Recording page: Power saving mode switch, "Kick in at (strap battery)" slider 10 to 35 step 5, "Pause HRV capture" switch, "Low refresh" switch, notes | `FS` `HostedPage` → `U/PowerSavingScreen.kt` | SAME | Same four controls (`power_saving_*`). Android's note text differs slightly. |
| S-13 | Strap page "Share strap log" | `SSC` Strap card button "Share strap log (for bug reports)" and `FSAB` `HelpSection` row | DIFFERENT | On iOS the strap log is in the Test Centre ("Report a bug with my log"). Android shows it twice (Strap card and Help). Keep one in each place only if the owner agrees. |
| S-14 | "What each strap can do" (Help › Guides) | `SSC` Strap card link "WHOOP 4.0 vs 5.0/MG" and Help | DIFFERENT | Duplicate entry on Android. See HLP-04. |

### 2.6 Strap Actions (iOS `AutomationsView(scope: .strapActions)`; Android hosted `U/AutomationsScreen.kt` `AutomationsScreen`)

Android's one `AutomationsScreen` shows both what iOS splits into Strap Actions and Notifications. iOS passes `scope` to
filter; Android has no scope.

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| SA-01 | Double-tap card: picker "When I double-tap" (Nothing, Buzz back, Mark a moment, Log a sleep mark, Buzz the time, Run a Shortcut…; Lock only on Mac), shortcut name field, "Test action", bond state pill, "Recent moments" list with Clear | `AutomationsScreen` "Double-tap" (`DoubleTapActionPicker`: NONE, BUZZ_BACK, MARK_MOMENT, SLEEP_MARK, HAPTIC_CLOCK; "Test action") | DIFFERENT | "Run a Shortcut…" and the shortcut field are Apple only (PLATFORM part). Missing on Android: bond state pill, "Recent moments" list with Clear (check whether moments are stored: `viewModel`). |
| SA-02 | Haptics card: four switches (Breathing pacer, Interval timer, Live Session cues, Workout start & end), default on | `AutomationsScreen` "Haptics" (`HapticPrefs`) | SAME | |
| SA-03 | Wear & presence: wrist-off and wrist-on Shortcut fields (iOS), lock-the-Mac switch (macOS) | none | PLATFORM | Shortcuts and Mac lock. No Android substitute. |
| SA-04 | Haptic coaching: "Heart-rate ceiling" switch with Ceiling source (Profile zone / Fixed BPM), Maximum allowed zone (Zone 1 to 5) or Heart-rate ceiling stepper, Warning frequency (Standard / Every 2 seconds), Monitor (Always / During workouts), "Buzz at N BPM" readout, disclaimer | `AutomationsScreen` "Haptic coaching": "HR-zone coaching" switch (buzz in Zone 5), "Recovery buzz" switch | DIFFERENT | Android's two switches are the older design. The ceiling engine is `HRCeilingAlertEngine` in StrandAnalytics (pure Swift, tested) and is not exposed to Android. Needs a core operation for the engine and the Bluetooth hook in `com.noop.ble` (cannot be validated without a strap, per AGENTS). |
| SA-05 | Haptic coaching: "Stress check-ins (haptic)" with Auto-nudge, Respect quiet hours, Use my resonance pace | `SSC` Health & wellness card: "Stress check-ins (haptic)", "Offer a breath automatically" | DIFFERENT | Placement (Lab › Health & wellness on Android). "Respect quiet hours" and "Use my resonance pace" missing. |

### 2.7 Notifications (iOS `AutomationsView(scope: .notifications)` + `LiveNotificationSettingsCard`; Android hosted `U/NotificationsSettingsScreen.kt`)

The two pages mean different things. iOS Notifications = lock-screen notifications plus every reminder; Android
Notifications = wrist alerts per app, calls, timers and phone daily reports. The content Android lacks here sits
elsewhere on Android.

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| N-01 | Live notifications card: Live heart rate, Workout, Strap sync switches (Lock Screen, Dynamic Island) | none | PLATFORM | Live Activities. Android substitute is the ongoing foreground notification (A-04), which has no per-kind switches. |
| N-02 | Wrist alerts: "Enable wrist alerts" master switch (gate for every wrist buzz) | `NotificationsSettingsScreen` "Wrist alerts" master (`NotifPrefs.MASTER`) + "Test buzz" | SAME | Android adds per-app lists and Test buzz (A-09). |
| N-03 | Inactivity reminder: switch, "Sitting for", "Re-nudge every", "Buzz strength" (steppers), "Only during active hours", From / to | `AutomationsScreen` "Inactivity reminder" (same controls) | DIFFERENT | Placement: Strap Actions page on Android, Notifications on iOS. |
| N-04 | Illness early-warning: "Watch for early-illness signs" | `AutomationsScreen` "Illness early-warning" and `SSC` Health & wellness "Illness heads-up" | DIFFERENT | Placement, and two switches on Android (check they write one preference). |
| N-05 | Health insights: Show cycle awareness, Cycle awareness, Remind me of my fertile days, Discreet on the Lock Screen, Rhythm visualization (experimental) + Open | `SSC` Health & wellness card: Show cycle awareness, Cycle awareness, Rhythm; fertile reminder inside the Cycle page (`F/ForgeCycle.kt`, `com.noop.notif.FertileReminder`) | DIFFERENT | Placement; Discreet switch missing in Settings. |
| N-06 | Battery alerts: "Notify on low and full battery", "Predictive runtime warning" | `AutomationsScreen` "Battery alerts" (same two) | DIFFERENT | Placement. |
| N-07 | Sync reminder: "Remind me when syncing stops" | none | PLATFORM | iOS only: a swipe away stops syncing on iOS, Android's foreground service survives it. |
| N-08 | Strain target: "Notify when optimal strain is reached" | `NotificationsSettingsScreen` "Daily reports" › "Optimal strain reached" | DIFFERENT | Placement and wording. |
| N-09 | Training load alert: "Notify when a lane is well above usual" (once per high phase) | none | MISSING | The once-per-high-phase decision is `TrainingLoadNotifier` in the app target (`Strand/System/`); not in the core. Needs the decision moved into a package and a core operation, then a Kotlin worker. The inputs (`training.load` with `usualLow`/`usualHigh`) are already on the core path. |

### 2.8 Training (iOS `SV` `trainingCard`, `guidedTrainingCard`; Android `FSGT` `TrainingSettingsSection`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| TRA-01 | Set effort: Off / RIR / RPE + note (core key `training.effortScale`) | `TrainingSettingsSection` | SAME | |
| TRA-02 | Session rating: Off / When useful / Always, refreshes reminders | `TrainingSettingsSection` (`CoreTrainingReminders`, `SessionRatingReminderWorker`) | SAME | |
| TRA-03 | Weight unit: Kilograms / Pounds + note | `TrainingSettingsSection` (core `training.weightUnit`) | SAME | |
| TRA-04 | Weight step: menu of increments (kg list or lb list), keys `training.weightIncrementKg`, `…LbKg` | none | SAME | Closed by package 1: Weight step picker (kg: 0.5, 1, 1.25, 2, 2.5, 5; lb: 1, 2.5, 5, 10) storing `training.weightIncrementKg` or `training.weightIncrementLbKg` in kilograms. Read through `TrainingStepPrefs.weightIncrementKg` by the plan builder and the plan templates. The Android set logger has typed fields and no − and + buttons, so there is no other consumer to wire; not a gap of this row. Was: UI + pref. `training.weightIncrementKg` is already read by `F/ForgePlans.kt` (plan progression). Add the keys to `CorePrefs` only if the core's draft stepping reads them; the stepper itself is in `F/TrainingSetInputs.kt`. |
| TRA-05 | "Sets for a new exercise: N" stepper 1 to 6 | `TrainingSettingsSection` (core) | SAME | |
| TRA-06 | Default rest stepper 0 to 600 step 15 | `TrainingSettingsSection` (core) | SAME | |
| TRA-07 | Warm-up rest stepper 0 to 300 step 15 | `TrainingSettingsSection` (core) | SAME | |
| TRA-08 | Rest-pause stepper 5 to 60 step 5 (`training.restPauseSeconds`) | none | SAME | Closed by package 1: Rest-pause stepper (5 to 60, step 5, default 20) storing `training.restPauseSeconds`; the rest started after a strap-completed rest-pause segment uses it (`ForgeTraining.kt` `startRest`). Android's draft sets carry no intensifier yet, so that is the only rest-pause set it can time. Was: UI + pref; `F/ForgeTraining.kt` already knows a "restPause" segment. Core key needed only if the core's workout draft reads it. |
| TRA-09 | When a timer ends: "Show a notification" | `TrainingSettingsSection` (`RestTimerPrefs`) | SAME | |
| TRA-10 | "Play a sound" (disabled while the notification is off) | `TrainingSettingsSection` | SAME | |
| TRA-11 | "Vibration" | `TrainingSettingsSection` | SAME | |
| TRA-12 | "Buzz the strap 5 seconds early" | `TrainingSettingsSection` | SAME | |
| TRA-13 | Note: sound only while the workout is open | `TrainingSettingsSection` `forge_st_timer_note` | SAME | |
| TRA-14 | "Lock Screen display" row → Notifications page | none | PLATFORM | Live Activity. |
| TRA-15 | "Strap double-tap completes a set" switch + note | `TrainingSettingsSection` (`RestTimerPrefs.STRAP_DOUBLE_TAP`) | SAME | |
| TRA-16 | Workout view: Focus / List / Compact | `TrainingSettingsSection` | SAME | |
| TRA-17 | Exercise media: Large / Small / Hidden | `TrainingSettingsSection` | SAME | |
| TRA-18 | "Manage offline exercise media" | `LinkRow` → `ForgeSettingsSub.ExerciseMedia` | SAME | |
| TRA-19 | "Available equipment": list of toggles (`training.availableEquipment`) + note | none in Settings; dialog in `F/ForgeExerciseLibrary.kt` (same key) | SAME | Closed by package 1: Training › "Available equipment" opens the new page `ForgeSettingsEquipment.kt`, the 11 items of iOS `knownEquipment` (core operation `profile.equipmentChoices`), same key as the library's dialog (`training.availableEquipment`). Was: Placement. Add a Settings row opening a page that edits the same key. UI only. |
| TRA-20 | "Keep screen on during a workout" + note | `TrainingSettingsSection` | SAME | Also duplicated in `SSC` Health & wellness. |
| TRA-21 | Note "units are under Language & Units" | `forge_st_units_note` | SAME | |
| TRA-22 | Guided training card: switch "Guided training" (Live Sessions, beta) with note | `SSC` Health & wellness "Live Sessions (beta)" | SAME | Closed by package 1: "Guided training" switch with its note, first in the Guided training card (`LiveSessionPrefs`, default on). Was: Placement. Not on the Forge Training page. |
| TRA-23 | "Detect activities" switch (asks notification permission, refreshes suggestions) | `TrainingSettingsSection` (`NoopPrefs.autoDetectWorkouts`) | SAME | |
| TRA-24 | "Help teach the app" row → `RawDonationView` + note | `FS` `Page` Training: a `HubRow` under the card; also Project page | SAME | Closed by package 1: "Help teach the app" is now a row with its note inside the Guided training card, as on iOS; the separate card under Training is gone (the Project page keeps its own entry, PJ-05). Was: Placement only. |
| TRA-25 | If detecting: "Detect walks" (disabled for a strap without steps: "This strap does not count steps.") | `TrainingSettingsSection` | SAME | |
| TRA-26 | "How often to ask": Detect more / Balanced / Only clear ones | `TrainingSettingsSection` | SAME | |
| TRA-27 | "Notify me" + "At most two a day, never at night." | `TrainingSettingsSection` | SAME | |

### 2.9 Today & Trends (iOS `todayCardsCard`; Android `FSA` `TodayCardsSection`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| TT-01 | "Water" switch (+ note; reads Apple Health on iOS) | `TodayCardsSection` | SAME | Note wording is platform. |
| TT-02 | "Journal card" switch | `TodayCardsSection` | SAME | |
| TT-03 | macOS only: Dashboard card (style picker, four Trends slot pickers, "Arrange dashboard" → `DashboardLayoutEditor`) | none; `FSA` `DashboardStyleSection` is private and has no caller (dead code) | PLATFORM | The old Today styles are gone on iPhone since 2026-11-20. Remove the dead Android composable only with the owner's word. |

### 2.10 AI Coach (iOS `CoachSettingsView`; Android hosted `U/CoachSettingsScreen.kt` + `U/CoachSettingsCards.kt`)

The row-by-row inventory is `COACH-PARITY.md` (section "Settings"); only the Settings-level differences are scored here.
Most coach settings come from the core (`CoreCoach`, `vm.coachSettings`, labels supplied by the core), so no new core
work is expected unless a row below says so.

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| CO-01 | Unconfigured: "Enable AI Coach" switch and a setup card (provider picker, server URL for a custom provider, API key with Save/Connect, model) | Coach tab owns setup; the Settings page shows only once a provider is connected (`CoachSettingsScreen` header comment) | DIFFERENT | Intentional on Android (a stored key belongs to one provider). `CoachFeatureCard` carries the Enable switch. |
| CO-02 | Configured: a hub of five subpages (Connection & model, Goal & Journey, Coaching, Memory, Privacy & data) | one flat scrolling page | DIFFERENT | Grouping and order. Splitting into subpages is optional presentation work in `CoachSettingsScreen.kt`. |
| CO-03 | Connection & model: provider pill, test connection, disconnect, forget key / forget all keys, model picker, refresh models, background models (summaries, card analyses, closer look), token usage, usage so far, OpenRouter balance | `CoachModelCard`, `CoachBackgroundModelsCard`, `CoachUsageCard` | DIFFERENT | Disconnect and update key sit in the chat menu; forget-all-keys and the OpenRouter balance check are not on the Android page (check `COACH-PARITY.md`, "Connection & model" is 🟡). |
| CO-04 | Goal & Journey row → `CoachGoalJourneyView` | `CoachSettingsScreen(onOpenGoals)` exists; the Forge hosting in `FS` `HostedPage` does not pass `onOpenGoals` | MISSING | One callback to pass (`onOpenIdentity`, `onOpenMemory`, `onOpenInfo` are passed; goals is not). UI only. |
| CO-05 | Coaching: Quick presets, Coach identity, Coaching style, Emoji, Reply length, Coach entry (banner, floating button, position, lock), Proactive messages, Morning suggestion, Morning brief, Daily check-in, Plan reminders | `CoachSharedSettingsCards`, `CoachTodayCard`, `CoachIdentityRow`, `MorningSuggestionSwitch`, `MorningBriefCard`, `CoachRemindersCard` | SAME | Per `COACH-PARITY.md`. |
| CO-06 | Memory: facts (category, edit, expiry, source), add, forget all, summarise past chats | `CoachNavRow` → `CoachMemoryPage` | SAME | |
| CO-07 | Memory: semantic memory switch with index status, Stop / Continue indexing, Rebuild / Delete index, Run model check | none | PLATFORM | Needs the Nomic model through llama; Android has no embedding model (plan decision, `COACH-PARITY.md`). |
| CO-08 | Privacy & data: let the coach use my data, privacy level (Essentials, Personal, Deep insights, Expert) with nine purpose switches, share patterns & Lab Book, Coach instructions editor, How Coach works | `CoachConsentCard`, `CoachSharedSettingsCards` (privacy level + purposes), `CoachInstructions`, `CoachInfoPage` | SAME | |

### 2.11 Siri & Shortcuts (iOS `SiriShortcutsSettingsView`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| SI-01 | Page: "Shortcut export" link, ready-made actions note, Shortcuts link ("Build your own") | none | PLATFORM | Apple only. |

### 2.12 Language & Units (iOS `languageCard`, `unitsCard`; Android `FSA` `LanguageUnitsSection`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| LU-01 | Language picker (System default + autonyms of `AppLanguage.allCases`) + note "takes effect after you reopen" | `LanguageUnitsSection` dialog over `AppLanguage.entries`; recreates the activity at once | SAME | Behaviour differs by platform; no note needed on Android. `U/AppLanguage.kt` has uncommitted edits in the main checkout (see section 5.4). |
| LU-02 | Clock: System default / 12-hour / 24-hour | `LanguageUnitsSection` (`ClockPrefs`) | SAME | |
| LU-03 | Week start: Monday / Sunday + note "Used by training, the weekly review, Trends and the goal calendar" (`training.weekStartsOn`) | none | MISSING | Surprising: five Android files already READ `training.weekStartsOn` (`ForgeWorkouts`, `ForgeStrengthOverview`, `ForgeTodayMoreWidgets`, `ForgeTrainingReports`, `FSGT`) and the core takes it as a call argument (`training.snapshot`), but no Android screen writes it, so Android is always Monday-first. Work: one `Segmented` row writing the key. Decide whether to add the key to `CorePrefs.keys` so core goal pacing can read it (verify how `goals.snapshot` gets the week start). |
| LU-04 | Units › Body: Metric / Imperial | `LanguageUnitsSection` (`NoopPrefs.setUnitSystem`) | SAME | |
| LU-05 | Distance & pace: Kilometres / Miles | `LanguageUnitsSection` | SAME | |
| LU-06 | Temperature: Follow body / °C / °F | `LanguageUnitsSection` | SAME | |
| LU-07 | Skin temperature: Temperature / vs baseline | `LanguageUnitsSection` | SAME | |
| LU-08 | Effort scale: 0-100 / 0-21 | `LanguageUnitsSection` (`UnitPrefs.setEffortScale`) | SAME | |
| LU-09 | Units blurb "Only changes what you see. NOOP always stores the same values." | `forge_settings_units_blurb` | SAME | |

### 2.13 Appearance (iOS `designCard` "Style", `backgroundCard`, `chartsCard`, `motionCard`; Android `FSA` `AppearanceSection`, `BackgroundCard`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| AP-01 | Preset (`ThemePreset`: recipes setting accent, chart style, backdrop and card opacity) | `SSC` `ThemePresetDropdown` (classic General card) | MISSING | Not on the Forge page. Needs `ThemePreset.matching` semantics; presentation only. |
| AP-02 | Theme: System / Light / Dark | `AppearanceSection` (`AppearancePrefs`) | SAME | |
| AP-03 | Color profile: Colorful / Stone / Slate / Sage (Forge skin; selecting it switches the day-cycle sky) | `AppearanceSection` (when `ForgeDesign.preview`; `ForgeColorProfile`) | DIFFERENT | The iOS onChange also sets the sky on for Colorful and off otherwise and mirrors to the app group; check that `ForgeColorProfile.set` does the sky part. |
| AP-04 | Accent picker (all `AccentColor` cases), shown only for Colorful | `AppearanceSection`: System Blue, Mint, WHOOP Blue (+ "Custom" only if already stored) | DIFFERENT | Option list shorter than `AccentColor.allCases`. |
| AP-05 | Custom colour (`ColorPicker`) when Accent = Custom | `SSC` `AccentCustomPicker` (classic) | MISSING | Not on the Forge page (`FORGE-PARITY.md` lists it as an open gap). |
| AP-06 | App icon: Default / Navy | `AppearanceSection` (`setAppIcon`, Titanium / Blue Titanium) | SAME | Different icon artwork per platform. |
| AP-07 | Coloured icons switch (`AppleInspiredColorsPrefs`; off keeps blue controls) | none | MISSING | Presentation only; consumers are the tile colours in `FS` `ForgeSettingsPage.tint()` and similar. Low value; confirm with the owner. |
| AP-08 | Hide tab bar when scrolling (iOS 26 only) | `SSC` classic Bottom bar card "Hide bar when scrolling" | PLATFORM | iOS 26 feature. Android's own switch is classic-only (A-12). |
| AP-09 | Swipe between tabs switch | none | MISSING | The behaviour itself is not known to exist on Android; ask before building. |
| BG-01 | Time-of-day sky switch + note | `BackgroundCard` (`ForgeBackground.dayCycle`) | SAME | |
| BG-02 | Motif: Alps / Coast / Meadow (disabled when the sky is off) | none | MISSING | Android has the Alps set only (`F/ForgeScene.kt`); Coast and Meadow artwork does not exist on Android. Needs the painted scenes (assets), then a `ForgeBackground.motif`. |
| BG-03 | Sky behind cards switch (disabled when the sky is off) | `BackgroundCard` (shown only while the sky is on) | SAME | |
| BG-04 | Transparent cards switch (+ note) | `BackgroundCard` | SAME | |
| BG-05 | Card transparency slider (0 to 100) + note | `BackgroundCard` `Slider` | SAME | |
| BG-06 | "Transparency on Today" slider (`todaySurfacePercent`, Forge preview) + note | none | MISSING | Check `ForgeTodayTile.kt` for a surface alpha before adding. |
| BG-07 | Custom photo: Choose from Photos / Replace, Browse files, Recent thumbnails (re-apply), "Custom photo" switch, Fit menu (`BackgroundFillMode`), Remove image, note | `SSC` classic "Background image" card (`U/BackgroundImage.kt` `BackgroundImageStore`) | MISSING | `ForgeScene.kt` already draws `BackgroundImageStore` when active, so only the controls are missing on the Forge page. Reuse the store. UI only. |
| CH-01 | Charts › Chart colours (`ChartStyle`) | `SSC` classic (Classic / Default) | MISSING | Check consumers first: no file under `F/` reads `ChartStyle`, `TrendChartStyle` or `SleepChartStyle` (only `U/Units.kt`, `U/SettingsScreen.kt`, `U/HealthVitalDetailLogic.kt`). A picker port would write preferences the Forge screens ignore. |
| CH-02 | Charts › Sleep chart (`SleepChartStyle`) | `SSC` classic | MISSING | Same remark. |
| CH-03 | Charts › Trend charts (`TrendChartStyle`) | `SSC` classic (Bars / Line) | MISSING | On iOS only `TrendsView` and `MetricExplorerView` read it, not the Forge screens. Decide with the owner whether the card should exist in the redesign at all. |
| MO-01 | Reduce motion switch + note | `AppearanceSection` `forge_ap_reduce_motion` | SAME | |
| MO-02 | Score rings: Living / Classic + note | `AppearanceSection` (`ScoreRingStyle`) | SAME | |
| MO-03 | Motion effect (rings lean as the phone moves; disabled with Reduce motion or Classic rings) | none | MISSING | The Forge rings on Android (`F/OrganicRing.kt`) have no tilt response; the classic liquid gauges do (`U/LiquidMotion.kt`). Feature absent, not only the switch. |
| MO-04 | Coach animation switch (the coach tile pulses) | none | MISSING | Check `F/ForgeCoachButton.kt`. |

### 2.14 Calculations (iOS `calculationCard`, `AnalysisMaintenanceSettingsCard`; Android `FSD` `CalculationsSection`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| CAL-01 | Day start: Falling asleep / Midnight + note per mode; recomputes recent days | `CalculationsSection` (`viewModel.setDayCycleMode`, `settings_day_cycle_*`) | SAME | |
| CAL-02 | HRV window: Whole night / Deep sleep; recomputes recent nights | `CalculationsSection` (Segmented, toast, `viewModel.syncNow`) | SAME | A second control for the same preference sits in the classic Strap card (S-08 note): keep one. |
| CAL-03 | Sleep stage method: V3 / V2 / V1 + note | `CalculationsSection` Segmented (when `CoreDailyRows.coreReads`), else the "Sleep staging V2" switch | SAME | |
| CAL-04 | Wake check switch | `CalculationsSection` (`experiment.motionAwareWake`) | SAME | |
| CAL-05 | If scores look wrong: status line while maintenance runs (phase, `AnalysisProgressFormat.detailLine`, `freshnessLine`) | none | MISSING | Needs progress from the core pass. |
| CAL-06 | "Refresh today" (`manuallyRefreshCurrentDayActivity`) | none | MISSING | Core: `IntelligenceEngine` method in StrandCore; no matching JNI operation seen. |
| CAL-07 | "Recalculate the last 21 days" with confirmation ("This can take several minutes…") (`manuallyReanalyzeRecent`) | none (Test Centre has sleep "Recompute") | MISSING | `manuallyReanalyzeRecent` is in StrandCore (`DailyAnalysis.swift`). Android reaches the pass through `shadowAnalyze` (`CoreShadow`); verify it can run 21 days with force and report progress, else new core operation `analysis.reanalyzeRecent`. Must not advance the recipe version (`AGENT_RULES`: manual reanalysis is diagnostics). |
| CAL-08 | "Reset Charge baseline" (confirmation, then "Charge baseline recalibrating" alert) + note | `CalculationsSection` row "Charge" → `ForgeSettingsSub.Charge` → hosted `SSC` Charge card, button "Recalibrate Charge baseline", dialog | DIFFERENT | Placement (one tap deeper), wording ("Recalibrate" vs "Reset"), and iOS keeps it in the "If scores look wrong" card. Already core-wired (`recoveryBaselineEpoch`, `hrvBaselineEpoch` in `CoreShadow.extras`). |

### 2.15 Data & Backup (iOS `backupCard`, `dataConnectionsCard`; Android `FSD` `DataBackupSection`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| DB-01 | Export… (backup file via a share/save step), Import… (replaces everything), Export CSV… (WHOOP-format zip) | `DataBackupSection` `LinkRow` x3 (`rememberBackupActions` in `F/ForgeBackup.kt`; CSV through `WhoopCsvExporter`) | SAME | |
| DB-02 | "Working…" indicator during backup | `F/ForgeBackup.kt` `Notice.Working` | SAME | |
| DB-03 | Result alerts: exported, imported (relaunch needed), oversize export, oversize restore (second confirmation, #1807), failure | `F/ForgeBackup.kt` `Notice` (`Exported`, `Imported`, `TooLarge`, `Failed`) | SAME | The CSV result is a toast on Android, an alert on iOS. |
| DB-04 | Info note "Importing overwrites everything currently on this device… relaunch" and warning "plain, unencrypted archive" | classic Backup card only; the Forge rows carry short detail lines | DIFFERENT | Add both notes to the Forge card (strings exist: `l10n_settings_screen_this_is_a_plain_unencrypted_archive_b0dfe63d`). |
| DB-05 | "Backup & Sync to a folder…" → `BackupSyncView` | `LinkRow` "Automatic backups" → `ForgeSettingsSub.BackupSync` | SAME | Wording. See 2.18 for the screen. |
| DB-06 | Apple Health row → `AppleHealthView` | `ForgeSettingsSub.DataSources` card "Health Connect" | PLATFORM | Android substitute: Health Connect (`U/DataSourcesScreen.kt`, `U/HealthConnectCategorySelector.kt`, `U/AppleHealthScreen.kt` is the per-source page shared with the Apple-export import). |
| DB-07 | Data Sources row ("WHOOP export, files and other wearables") → `DataSourcesView` | `LinkRow` → `ForgeSettingsSub.DataSources` | SAME | |
| DB-08 | Shortcuts Export (iOS) | none | PLATFORM | |
| DB-09 | Storage row ("Where NOOP's on-device space is going, and a one-tap clean-up") → `StorageView` | none | MISSING | iOS data: `AppModel.StorageReport` (database file with WAL and SHM size from `WhoopStore.databaseFileSizeBytes()`, `Documents/Inbox/`, import temp files). The database size is a store call; Android has no JNI operation for it, but the file sizes of the Android database and cache are plain platform file reads. Decide: new core operation `storage.report` (preferred, keeps iOS and Android in step) or Kotlin file sizes. |
| DB-10 | "Steps from" picker (Automatic / Strap / Apple Health) with note; a change rebuilds the AgeLess weeks and refreshes (iOS: on the Devices and data sources page) | `FSD` `StepsSourceCard` (core `steps.setSource`) | DIFFERENT | Placement (Data & Backup, not Devices and data sources); third option reads "Health Connect". |

### 2.16 Help & Diagnostics (iOS `guidesCard`, `testCentreCard`, `rawSensorDiagnosticsCard`, `deviceInfoCard`; Android `FSAB` `HelpSection`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| HLP-01 | How NOOP works (sheet) | `HelpSection` → `ForgeSettingsSub.HowNoopWorks` → `U/HowNoopWorksScreen.kt` | SAME | |
| HLP-02 | How your scores work (sheet) | `HelpSection` → `ScoringGuide` → `U/ScoringGuideScreen.kt` | SAME | |
| HLP-03 | About Apple Watch data (`AppleWatchAboutView`, setup sheet) | none | PLATFORM | |
| HLP-04 | What each strap can do (`NoopLimitationsView`) | `HelpSection` → `Limitations` → `U/NoopLimitationsScreen.kt` | SAME | Android also has a second page (A-10). |
| HLP-05 | Test Centre card: "Open Test Centre" | `HelpSection` card Diagnostics, `LinkRow` Test Centre | SAME | See 2.18. |
| HLP-06 | Diagnostics card: "Export raw sensor data (CSV)" (last 24 hours, read-only, share sheet) + note | `SSC` Advanced › Diagnostics card only | DIFFERENT | Missing from the Forge Help page; reachable only through All settings › Advanced. Exporter is Kotlin (`LogExport`/the card's own code): confirm the export lives in the core or its decode path. |
| HLP-07 | "This iPhone" card: Diagnostics sheet (device, iOS build, Data Protection, sideload status, Copy), "Using NOOP on iPhone" expectations with expiry warning | none | PLATFORM | Sideloaded-iPhone facts. Android substitute: the Test Centre environment dump. |

### 2.17 Lab (iOS `labCard`, Oura card, `fiveMGCard`; Android `FSAB` `LabSection`, hosted `SSC` Advanced)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| LAB-01 | Tile board (debug builds only) | none | PLATFORM | iOS DEBUG only. |
| LAB-02 | Personal stress baseline switch + note | `FSD` `CalculationsSection` (Scores/Sleep card) | DIFFERENT | Placement: Calculations on Android, Lab on iOS. |
| LAB-03 | Training-based VO₂max switch | `LabSection` (`CoreFeatures`) | SAME | |
| LAB-04 | Strength in Effort switch (re-analyses history reusing unchanged days) | `LabSection` (`viewModel.setEffortStrengthBonus`) | SAME | |
| LAB-05 | AgeLess switch | `LabSection` | SAME | |
| LAB-06 | Daily rhythm switch | `LabSection` | SAME | |
| LAB-07 | Oura card (Oura only): "Oura ring: all-day heart rate & HRV" | none | MISSING | Oura live HR is Kotlin BLE (`com.noop.ble.OuraLiveSource`); needs the ring to test. Low priority (Oura is experimental). |
| LAB-08 | WHOOP 5/MG card (only with 5/MG controls): Try 5/MG protocol probes, R22 unlock with send/clear and reports, ECG raw-data gate on/off with report, ECG capture switch (+ disclaimer), Record puffin frames, Optical block experiment (Mark phase…, Export experiment…), Export frames…, Export raw + log | `LabSection` › Advanced › "Experimental · WHOOP 5 / MG" (probes, R22, ECG gate) ; ECG capture and raw capture sit in Test Centre ("5/MG protocol diagnostics") | DIFFERENT | Android lacks Record puffin frames in this card, the Optical block experiment (Mark phase…, Export experiment…) and Export raw + log. Needs strap hardware; do not port blind. |

### 2.18 Screens below the pages (compared at screen level only)

The Settings pages above are compared control by control. The deeper screens are large; here only existence and
placement are scored. The first task of the owning package is a control-level diff of each (the iOS Test Centre
alone is 1,402 lines and the Android one 1,404).

| ID | iOS screen | Android counterpart | Status | Notes |
|---|---|---|---|---|
| SUB-01 | `TestCentreView` (probe toggles, recalibrate, skin-temp backfill, scheduled export, test modes, raw-data collector, protocol diagnostics, experimental algorithms, Oura options, report-a-bug flow) | `U/TestCentreScreen.kt` `TestCentreScreen` | SAME | Screen-level. Both repos keep them in step (`Tools/test_android_ios_parity.py`). |
| SUB-02 | `BackupSyncView` (folder, daily auto-backup, keep last N, Back up now, Restore from a backup…) | `U/BackupSyncScreen.kt` `BackupSyncScreen` | SAME | Android adds "Backup time" (A-17). iOS "NOOP's own folder (Files)" and "Move to iCloud Drive" are PLATFORM. |
| SUB-03 | `DataSourcesView` | `U/DataSourcesScreen.kt` `DataSourcesScreen` | SAME | Screen-level. |
| SUB-04 | `StorageView` | none | MISSING | See DB-09. |
| SUB-05 | `HeartRateSharingView` | `U/DataSourcesScreen.kt` card + `SSC` Advanced switch | DIFFERENT | See S-09. |
| SUB-06 | `NoopLimitationsView` | `U/NoopLimitationsScreen.kt` | SAME | Screen-level. |
| SUB-07 | `HowNoopWorksView`, `ScoringGuideView`, `WhatsNewView` | `HowNoopWorksScreen`, `ScoringGuideScreen`, `WhatsNewSheet` | SAME | Screen-level. |
| SUB-08 | `ExerciseMediaManagementView` | `F/ForgeExerciseMedia.kt` (`ForgeExerciseMediaSettings`) | SAME | Screen-level. |
| SUB-09 | `StepsCalibrationSheet` (explainer, current fit, estimate vs phone table, manual coefficient slider) | `U/StepsCalibrationScreen.kt` | SAME | Screen-level; entry is the problem (S-11). |
| SUB-10 | `AcknowledgementsView`: third-party content entries (MuscleMap, react-native-body-highlighter, ExerciseDB v1, provider attribution, exercise media licence note, licence texts) and "People whose work NOOP Forge adopted" (25 contributors, `Contributor` list) | `F/ForgeExerciseProviderAcknowledgements.kt` (provider attribution only) | DIFFERENT | The contributors list and the other entries are missing on Android, although `AGENT_RULES.md` requires adopted contributors to appear in `AcknowledgementsView.contributors`. The list is static Swift data today; for one source of truth put it in StrandCore and read it over a core operation (core first), or generate Android resources from it. |
| SUB-11 | `AppleHealthView`, `AppleWatchAboutView`, `AppleWatchSetupView`, `ShortcutExportSettingsView`, `DashboardLayoutEditor` (macOS), `BodyView` (from Profile, classic) | none (Health Connect in `DataSourcesScreen`; Body is a Health tab) | PLATFORM | |
| SUB-12 | `HRZoneEditorSheet` | none (zones are steppers in the Profile card) | SAME | See PRO-14. Was: See PRO-14. |
| SUB-13 | `TrainingEquipmentSettingsView` | dialog in `F/ForgeExerciseLibrary.kt` | SAME | See TRA-19. Was: See TRA-19. |

### 2.19 About (iOS `aboutCard`; Android `FSAB` `AboutSection`)

| ID | iOS item | Android counterpart | Status | Notes |
|---|---|---|---|---|
| ABT-01 | "NOOP" + version pill + "What's new" button (sheet) | `AboutSection` version row; "What's new" `LinkRow` → `ForgeSettingsSub.WhatsNew` | DIFFERENT | Placement and control (button against row). |
| ABT-02 | Build stamp line (selectable text, `LiveState.buildStamp`) | none (`BuildIdentity.uiVersion` is shown inside the version row) | MISSING | `BuildIdentity.kt` holds the data. UI only. |
| ABT-03 | Acknowledgements row | `AboutSection` `LinkRow` → `ForgeSettingsSub.Acknowledgements` | DIFFERENT | The screen is provider-only, see SUB-10. |
| ABT-04 | Check for updates (spinner, "You're on the latest (v)", "Couldn't check. Try again.") | `AboutSection` (`UpdateCheck.check`) | SAME | |
| ABT-05 | "Check automatically" switch with note | `AboutSection` (`UpdateWatch`) | SAME | |
| ABT-06 | Update available: "Version X is available", Download button, scrollable release notes box | `AboutSection`: text + "Open" button | DIFFERENT | Release notes missing. |
| ABT-07 | Note "Checks the project's home (GitHub)… Nothing else is sent." | classic About only | DIFFERENT | Add to the Forge card. |
| ABT-08 | "Project home & source" link row | `AboutSection` TextButton `forge_settings_source` | SAME | Wording. |
| ABT-09 | "Support the project" (Ko-fi) link row | none in Forge About (classic has "Support & contact", an e-mail address, A-14) | MISSING | `ProjectLinks.support`. Confirm with the owner before adding a donation link to the Android app. |
| ABT-10 | Text block: "A standalone companion for your WHOOP…", the not-a-medical-device warning, "Built on" attributions (johnmiddleton12/my-whoop, b-nnett/goose), thanks line | classic About only | MISSING | Forge About lacks all four. Strings exist (`l10n_settings_screen_noop_is_not_a_medical_device…`). UI only. |

---

## 3. Android-only items (iOS has no counterpart): do not drop

Everything here is either Android platform work (services, Bluetooth stack, permissions) or an Android control iOS
removed or never had. Porting the iOS layout must keep them reachable, by moving them where the table says or by leaving
them where they are. "Where" is the file that draws it today.

| ID | Item | Where today | What to do |
|---|---|---|---|
| A-01 | "All settings" row on the hub and the page behind it (`ForgeSettingsSub.AllSettings`, hosts every classic card but Backup) | `FS` `NewDesignHub`, `SubScreen` | Keep until every classic control has a Forge home; this page is the only way to reach several controls today (step correction, Preset, custom accent, custom background, Charts, Bottom bar, raw sensor CSV, Gauge numbers, Effort exponential). Remove only with the owner's word. |
| A-02 | Profile › Name text field | `FSP` `ProfileSection` | Keep. (iOS Profile has no name field.) |
| A-03 | Profile › "Use weight from Health Connect" switch and the "From Health Connect" note | `FSP`, `U/HealthConnectWeightSync.kt` | Keep. Substitute for Apple Health weight on iOS. |
| A-04 | Android keep-alive set: "Keep connected in the background" (foreground service and its notification), "Faster history sync (experimental)", "Faster Bluetooth link (experimental)", "Keep NOOP alive overnight" (battery-optimisation exemption with "Allow") and the OEM auto-start hint | `SSC` Strap card | Keep; belongs on the Forge Strap page (S-01). Substitute for iOS "Keep screen on while syncing" and Live notifications. |
| A-05 | Bond experiments: "Ask Android to pair", "Try history sync without pairing", "Send hello despite bond refusal" | `SSC` Advanced card | Keep (Android bond path, `com.noop.ble`). iOS bonding has no equivalent. |
| A-06 | WHOOP 5/MG rename (experimental) and "Check current name (read-only)" | `SSC` Strap card | Keep next to S-06. |
| A-07 | Self-hosted push (#1314) page: one-way export to the user's own endpoint | `ForgeSettingsSub.SelfHostedPush` → `SelfHostedPushScreen`; `FSD` `DataBackupSection` row | Keep. Not on iOS at all. |
| A-08 | "Share strap log (for bug reports)" shown twice (Strap card and Help) | `SSC`, `FSAB` `HelpSection` | Keep one in Help; the Strap-card copy can move once Test Centre is linked from the Strap page (S-05). iOS has it inside Test Centre only. |
| A-09 | Notifications content: per-app wrist alerts (Notification Access, app list, per-app switch, pattern menu), Timer & alarm, Behaviour (Only buzz when worn, Answers to my reports, All other apps, Quiet hours with From/To), Daily reports (Morning recap, Post-workout summary, Optimal strain reached), Calls (phone and VoIP) | `U/NotificationsSettingsScreen.kt` | Keep. iOS has this only on macOS (`NotificationSettingsView`, per-Mac-app list). Its "Behaviour" and "Quiet hours" ideas also apply to iOS reminders: iOS Goals notifications say "Quiet hours from the notification settings apply". |
| A-10 | "WHOOP 4.0 vs 5.0/MG" comparison page | `FSAB` `HelpSection`, `U/WhoopModelComparisonScreen.kt` | Keep. iOS's "What each strap can do" is the Limitations page; Android has both. |
| A-11 | Nap detection: "Detect short naps" and the review list (accept, dismiss) | `U/AutomationsScreen.kt` `NapDetectionSection` | Keep. |
| A-12 | Classic-only Appearance controls: Gauge numbers (Bold/Softer), Ring gauges on Today, Bottom bar card (AI Coach switch, Bottom bar overlay, Hide bar when scrolling, Bar size, Bar transparency), "Effort: exponential intensity scale" switch (Banister) | `SSC` General card, via All settings | Keep reachable. Note: the core ignores `effortBanister` since #2438 (`CoreAnalysis.Settings`, comment "retained for the legacy JNI ABI"), so the Effort switch changes nothing in the core path: ask the owner whether to remove it. |
| A-13 | "Classic screens" row in About: turns the Forge UI off (`ForgeUi.setEnabled(context, false)`, not `ForgeDesign`) and restarts into the classic app; its detail text says it is for what the new screens do not cover yet | `FSAB` `AboutSection` | Keep until the controls reachable only through All settings (A-01) have Forge homes; remove only with the owner's word. |
| A-14 | "Support & contact": opens a mail to the project address (anonymous project) | `SSC` About card (`SUPPORT_EMAIL`) | Keep. |
| A-15 | Lab › "Compare with the phone's copy" (core against the old Room copy) | `FSAB` `LabSection` | Keep or retire with the Room copy; Room is gone from the app (`AGENT_RULES.md`), so it may already be dead: verify before porting anything next to it. |
| A-16 | Lab › "Health & wellness" and "Advanced" sub-pages as grouping | `FS` `ForgeSettingsSub.HealthWellness`, `Advanced` | Keep until the controls inside have iOS-shaped homes: Health & wellness holds Illness heads-up, Show/Cycle awareness, Hydration, Auto-detect workouts, Journal reminder, Keep screen on, Live Sessions, Stress check-ins, Offer a breath automatically, Rhythm, Share on-device signals with the Coach. Several duplicate controls already on Forge pages (Hydration, Journal, Auto-detect, Keep screen on). |
| A-17 | Backup time picker and the "backup around 1am" behaviour | `U/BackupSyncScreen.kt` | Keep (SAF folder based, Android). |
| A-18 | "Enable AI Coach" switch (`NoopPrefs.coachEnabled`, the Android bottom-bar coach button) | `U/CoachSettingsCards.kt` `CoachFeatureCard` | Keep (also a classic Bottom bar switch, A-12). |
| A-19 | Android Test Centre probes (history-sync experiments, bond traces, ECG probe start/stop) | `U/TestCentreScreen.kt` | Keep. |
| A-20 | `ProjectSharingCard` on the Project page | `F/ForgeRoadmap.kt` | Keep. |
| A-21 | Health Connect: import card, category selector, weight sync | `U/DataSourcesScreen.kt`, `U/HealthConnectCategorySelector.kt` | Keep; the Android substitute for Apple Health. |
| A-22 | Haptic coaching: "HR-zone coaching" (triple buzz in Zone 5) and "Recovery buzz" | `U/AutomationsScreen.kt` | The iOS card replaced these with the Heart-rate ceiling. Keep until SA-04 is built, then migrate the stored preference rather than dropping the user's choice. |
| A-23 | `DashboardStyleSection` (private, no caller) | `FSA` | Dead code; leave until the owner agrees to delete. |

---

## 4. What each gap needs: UI only, existing core input, new core API, or a strap

Rule (AGENT_RULES): logic lives in `Packages/`; Android adds Bluetooth transport, Android services and presentation.
A change to the core changes both platforms, and `Tools/local-tests.sh` builds Android for any change under
`Packages/**`. Every commit must record `Analysis migration required: yes/no`. None of the gaps below changes a scoring
formula. Two of them (PRO-12 VO₂max, PRO-13 Activity level) feed an input of the energy model that Android never sent,
so the porter must decide, with the owner, whether the first value a user enters can leave stored energy stale
(then it is "yes" and follows the one-bump-per-release rule), or is picked up by the normal pass (then "no").

### 4.1 UI only (presentation or a Kotlin-side preference; no core)

H-03, H-06, H-07, H-13, H-14, H-15, H-16, PRO-01, PRO-03, PRO-15, S-01, S-03, S-05, S-08, S-10, S-11, S-13, S-14, SA-01
(moments list), N-03, N-04, N-05 (placement), N-06, N-08, TRA-04 and TRA-08 (preference plus consumers in
`F/TrainingSetInputs.kt` and `F/ForgeTraining.kt`; add to `CorePrefs.keys` only if a core call reads them),
TRA-19, TRA-22, TRA-24, LU-03, AP-01, AP-03, AP-04, AP-05, AP-07, AP-09, BG-06, BG-07, CH-01 to CH-03 (after the
consumer question), MO-03, MO-04, CAL-08, DB-04, DB-05, DB-10, HLP-06, LAB-02, ABT-01 to ABT-08, ABT-10, CO-02, CO-04.

Check before starting LU-03: the week start is read by five Kotlin files from `NoopPrefs` and by the core only as a
call argument, so the Kotlin writer is enough for the UI. Whether the core's goal pacing (`goals.snapshot`,
"training goals spread their pace over the other days") should read it itself is a question for the Swift side
(`CoreGoals.swift`); if yes, the key joins `CorePrefs.keys`.

### 4.2 Kotlin wiring of inputs the core already accepts

| Item | What exists in the core | What Android lacks |
|---|---|---|
| PRO-12 VO₂max (manual), PRO-13 Activity level | `CoreAnalysis.applyExtras` reads `manualVO2max`, `manualVO2maxDay`, `manualVO2maxWeightKg`, `activityLevelOverride`; `PeakMETResolver`, `JurcaFitness` do the scoring | `ProfileStore` fields, the Profile rows, and three `put(...)` lines in `CoreShadow.extras`. Android has an unrelated key `energy.activityLevel` in `C/CoreEnergyPlan.kt`: reconcile first. |
| PRO-09 waist | `waistCm` already sent | nothing |
| CAL-08 Reset Charge baseline | `recoveryBaselineEpoch`, `hrvBaselineEpoch` already sent | nothing (placement and wording only) |
| LAB-03 to LAB-06, CAL-04 | already sent (`effortStrengthBonus`, `healthspan`, `rhythmAge`, `motionAwareWake`) | nothing |
| CAL-07 Recalculate 21 days | `IntelligenceEngine.manuallyReanalyzeRecent` (StrandCore); Android runs passes through `CoreShadow.shadowAnalyze` | Verify `shadowAnalyze` can be asked for 21 days with force and progress; if not, it is 4.3. |

### 4.3 Needs new core API (Swift in `Packages/`, a `CoreCall` operation, a Kotlin object, a parity test)

| Item | Why | Proposed operation (names are suggestions) |
|---|---|---|
| CAL-05, CAL-06, CAL-07 | Analysis maintenance (phase, progress, freshness, "Refresh today", "Recalculate 21 days") lives in `IntelligenceEngine` and `AnalysisProgressFormat` | `analysis.maintenance` (status JSON with the formatted lines), `analysis.refreshToday`, `analysis.reanalyzeRecent`. Must not advance `AnalysisRecipe.currentVersion` (manual reanalysis is diagnostics). |
| PRO-11 (measured max-HR caption), PRO-12 (BMI hint) | `ProfileStore.measuredMaxHeartRate` is app-side; `PeakMETResolver.measurementAdvised` is in StrandCore | `profile.maxHeartRateSource`, `energy.measurementAdvised` (or one `profile.facts` call) |
| PRO-06 body-composition formula | The Navy equation choice must reach the body-fat estimate; no sex argument in `CoreBody.swift` today | Add `bodyFormulaSex` to the `body.snapshot` request, or confirm Android computes Navy elsewhere (then that code is a violation to move) |
| N-09 Training load alert | Once-per-high-phase decision is `TrainingLoadNotifier` in `Strand/System/` | Move the decision to a package (`TrainingLoadAlert`), expose `alerts.trainingLoad` (input: the `training.load` lanes with `usualLow`/`usualHigh` and the stored per-lane state; output: notify or not and the new state) |
| SA-04 Heart-rate ceiling | `HRCeilingAlertEngine` is pure in StrandAnalytics and tested; no JNI operation | `alerts.hrCeiling` (state in, decision out); the buzz is sent by `com.noop.ble`, which needs a strap to verify |
| GOA-04 period-goal notifications (Start of week, Mid-week, Review) | `GoalPrefs.NotificationKind` and the notice planning are in the app and core (`goals.notices`) | Check `CoreGoalNotices.swift`; if the plan already includes these kinds, only the Kotlin settings and worker are missing |
| DB-09 / SUB-04 Storage | `AppModel.storageReport` is app-side (store file size, import inbox) | `storage.report` (database file with WAL and SHM, the sum of import temp files), or Android reads its own file sizes in Kotlin (acceptable only as Android file-system presentation) |
| SUB-10 / ABT-03 Acknowledgements | `AcknowledgementsView.contributors` (25 people) and the third-party entries are Swift data | Move to StrandCore (`Acknowledgements`), expose `about.acknowledgements`, let both screens render it; the fork's credit rule then holds on both platforms from one list |
| TRA-04, TRA-08, LU-03 (only if the core reads them) | `CorePrefs` whitelist (13 keys) | add keys to `CorePrefs.keys` in Swift and `CorePrefs` in Kotlin, with a range, and a line in `CorePrefsTests.swift` |

### 4.4 Cannot be verified without hardware or an artwork decision

S-09 (strap-side sharing status, "Stop sharing on the strap"), SA-04 (ceiling buzzes), LAB-07 (Oura all-day HR), LAB-08
(optical experiment), S-06 (5/MG rename), BG-02 (Coast and Meadow scenes are artwork Android does not have), MO-03
(tilt response on the Forge rings). AGENTS.md: BLE behaviour must be tested on a real strap and the report must say what was
tested.

---

## 5. Work split for parallel porting

Six packages, ordered by how little they depend on each other. No Kotlin or Swift file appears in two packages.
Section 5.2 lists the shared files that every package would otherwise touch and how to keep them conflict free.

### 5.1 Packages

**Package 1: You and Training** (Profile, Goals, Training, heart-rate zones, equipment)
Rows: the ones listed for this package in 5.5.
Files it edits:
- `F/ForgeSettingsProfile.kt`, `F/ForgeSettingsGoalsTraining.kt`
- new `F/ForgeSettingsHrZones.kt` (zone editor page, Standard / Beats), new `F/ForgeSettingsEquipment.kt` (equipment page for `training.availableEquipment`)
- `U/ProfileStore.kt` (after P0 moves `ProfileStore` out of `SettingsScreen.kt`): new fields `vo2maxManual`, `vo2maxManualDay`, `vo2maxManualWeightKg`, `activityLevelOverride`, `bodyFormulaSex`, zone mode
- `C/CoreShadow.kt` (`extras`: the VO₂max and activity-level keys). Note: this file has uncommitted edits elsewhere, see 5.4.
- `F/ForgeGoals.kt` (`GoalNotificationsCard`, the three period kinds) and `com/noop/notif/GoalNoticeNotifier.kt`
- `F/TrainingSetInputs.kt`, `F/ForgeRestTimer.kt` only for the weight-step and rest-pause consumers
- Swift: `Packages/NoopCoreJNI/Sources/NoopCore/CoreBody.swift` only if PRO-06 needs the new argument; tests in `Packages/NoopCoreJNI/Tests/NoopCoreTests/`
Does not touch: `U/SettingsScreen.kt` (classic General card stays as it is), `FS`.

**Package 2: Strap and Devices** (Strap page, Battery & Recording, Heart rate sharing, steps entries, Devices and data sources page)
Rows: the ones listed for this package in 5.5.
Files:
- new `F/ForgeSettingsStrap.kt` (grouped Strap page, a Forge-native Strap card with the status/connection rows, the steps rows, the Test Centre row, heart-rate sharing), new `F/ForgeSettingsDevicesSources.kt`
- `U/SettingsScreen.kt` (the only package allowed to edit it: split the Strap and Advanced cards so the Forge page can host the pieces; leave every other card as is)
- `U/PowerSavingScreen.kt` (Continuous HRV moves here, S-08), `U/DataSourcesScreen.kt` (phone broadcaster status), `U/StepsCalibrationScreen.kt`
- `com/noop/ble/HrBroadcaster.kt` only for the sharing status (hardware-verified)
Does not touch: `FS` (routes are pre-registered by P0), `U/AutomationsScreen.kt`.

**Package 3: Strap Actions and Notifications**
Rows: the ones listed for this package in 5.5.
Files:
- `U/AutomationsScreen.kt` (adds `scope`: strap actions, notifications, all; moves cards so each page shows what iOS shows; hosts the new Heart-rate ceiling card and the stress check-in rows), `U/NotificationsSettingsScreen.kt`, `U/HapticPrefs.kt`, `U/InactivityPrefs.kt`
- new `F/ForgeSettingsAlerts.kt` (the Forge-native "Alerts and reminders" page that lists inactivity, illness, health insights, battery, strain target, training load; hosts the existing wrist-alert screens)
- new `com/noop/notif/TrainingLoadNotifier.kt` and its worker, `com/noop/ble/` hook for the ceiling buzz (`WhoopBleClient.kt`, hardware verified)
- Swift: new `Packages/NoopCoreJNI/Sources/NoopCore/CoreAlerts.swift` and Kotlin `C/CoreAlerts.kt` (operations `alerts.trainingLoad`, `alerts.hrCeiling`); a `TrainingLoadAlert` type in a package (StrandCore or StrandAnalytics) that the iOS `TrainingLoadNotifier` also calls (an iOS edit in `Strand/System/TrainingLoadNotifier.swift`)
Does not touch: `U/SettingsScreen.kt` (stress check-in and illness rows already live in the classic Health & wellness card; rebuild them in the new file, do not edit the card).

**Package 4: Display** (Language & Units, Appearance, Today & Trends)
Rows: the ones listed for this package in 5.5.
Files:
- `F/ForgeSettingsAppearance.kt`, new `F/ForgeSettingsBackgroundPhoto.kt` (custom photo controls over `BackgroundImageStore`), new `F/ForgeSettingsCharts.kt` (only if kept)
- `U/BackgroundImage.kt`, `F/ForgeTheme.kt` (`ForgeColorProfile`, `ForgeAccent`: the full accent list and a custom colour picker), `F/ForgeScene.kt` (motif, plus the artwork in `res/drawable-nodpi`), `F/ForgeClassicRing.kt` / `F/OrganicRing.kt` (tilt response, only if the owner wants MO-03), `F/ForgeCoachButton.kt` (coach animation)
- `U/Units.kt` (only if a week-start helper belongs there; the preference itself is `training.weekStartsOn` in `NoopPrefs`)
Does not touch: `U/AppLanguage.kt` (in flight elsewhere, 5.4), `U/MainActivity.kt` (see 5.2).

**Package 5: Data and Calculations**
Rows: the ones listed for this package in 5.5.
Files:
- `F/ForgeSettingsData.kt`, new `F/ForgeSettingsStorage.kt` (Storage page), new `F/ForgeSettingsScoreRepair.kt` ("If scores look wrong": status, Refresh today, Recalculate 21 days with confirmation, Reset Charge baseline; re-implements the recalibration dialog instead of editing the classic Charge card)
- `F/ForgeBackup.kt`, `U/BackupSyncScreen.kt`, `U/BackupSync.kt`
- Swift: new `CoreStorage.swift`, new `CoreAnalysisMaintenance.swift` in `Packages/NoopCoreJNI/Sources/NoopCore/`, Kotlin `C/CoreStorage.kt`, `C/CoreAnalysisMaintenance.kt`; an iOS `StorageView` / `AnalysisMaintenanceSettingsCard` change only if the logic moves into a package they both call
Does not touch: `U/DataSourcesScreen.kt` (package 2); a gap found there goes to package 2.

**Package 6: Shell, Help, Lab, About, Coach, Project**
Rows: the ones listed for this package in 5.5.
Files:
- `F/ForgeSettings.kt` (the only package to edit it after P0: hub order, wording, search words, page picture header, "Your model" tab, `onOpenGoals` for the Coach page)
- `F/ForgeSettingsComponents.kt`, `F/ForgeSettingsAbout.kt` (`HelpSection`, `LabSection`, `AboutSection`), new `F/ForgeSettingsAcknowledgements.kt`
- `F/ForgeMoreIndex.kt` (search words and the Settings search entry), `U/CoachSettingsScreen.kt`, `U/CoachSettingsCards.kt`, `U/WhatsNewSheet.kt`, `U/TestCentreScreen.kt` (control-level diff first; edits only for gaps found), `F/ForgeRoadmap.kt` (only if the Project page needs a change)
- Swift: new `Packages/StrandCore/Sources/StrandCore/Acknowledgements.swift` and `Packages/NoopCoreJNI/Sources/NoopCore/CoreAcknowledgements.swift`, Kotlin `C/CoreAcknowledgements.kt`; iOS `Strand/Screens/AcknowledgementsView.swift` (reads the shared list)
Does not touch: pages owned by packages 1 to 5.

### 5.2 Shared files and how to keep them conflict free

| Shared file | Why everyone needs it | Rule |
|---|---|---|
| `F/ForgeSettings.kt` (`ForgeSettingsPage`, `ForgeSettingsSub`, `SubScreen`, `HostedPage`) | Each new page or subpage needs an enum entry and a `when` branch | One **skeleton commit (P0)** before the packages start: add every new enum entry and branch, each calling a stub composable that lives in the owning package's new file (`internal fun StorageSettingsPage(onBack: () -> Unit) = Unit` style). After P0 only package 6 edits this file. |
| `android/app/src/main/res/values*/strings.xml` (nine files) | Every new row needs a key in all locales | P0 adds, in the base file and each locale file, six anchored blocks `<!-- settings-parity:pN:begin -->` to `<!-- settings-parity:pN:end -->`, each separated from the next by at least three untouched lines. A package edits only its own block, so git sees six separate hunks. Prefix keys with the package (`fsp1_`, `fsp2_` … `fsp6_`) so two packages never define one name. A final integrator step moves nothing; the anchors are removed after the last merge. |
| `U/MainActivity.kt` (holds `object NoopPrefs`) | New SharedPreferences accessors | Do not edit it. Each package keeps its accessors in a `…Prefs` object in its own new file (as `RestTimerPrefs` does in `F/ForgeRestTimer.kt`), reading `NoopPrefs.of(context)`. |
| `Packages/NoopCoreJNI/Sources/NoopCore/CoreCall.swift` (the operation switch) | Every new core operation needs a `case` | P0 adds all new `case` lines up front, each calling `run(args:)` of a new per-package stub enum (`CoreAlerts`, `CoreStorage`, `CoreAnalysisMaintenance`, `CoreAcknowledgements`) that answers `{"error":"unimplemented"}`. Packages fill only their own file. This file has uncommitted edits in the main checkout (5.4). |
| `Packages/NoopCoreJNI/Sources/NoopCore/CorePrefs.swift` and `C/CorePrefs.kt` | New whitelisted keys (`training.weightIncrementKg`, `training.weightIncrementLbKg`, `training.restPauseSeconds`, `training.weekStartsOn`, `training.availableEquipment`) | Decide in P0 which of these the core must read, add them with type and range and a test line, and leave the files alone afterwards. |
| `U/SettingsScreen.kt` (classic, 4,500 lines, also holds `ProfileStore`) | Strap card (package 2), `ProfileStore` fields (package 1) | P0 moves `ProfileStore` and its small helpers (`waistCmStep`, `waistInchesStep`, `StepsCalibrationFormat`) into `U/ProfileStore.kt`. Afterwards only package 2 edits `SettingsScreen.kt`; no package edits the General, Charge, Backup, About or Health & wellness cards. |
| `Tools/i18n_audit_baseline.json`, `Tools/i18n_extra_locale_baseline.txt` | Hardcoded-literal and locale baselines | Do not add literals (every string through `stringResource`). Run `python3 Tools/i18n_audit.py --ci origin/main` before each push. |
| `docs/fork/android/SETTINGS-PARITY.md`, `FORGE-PARITY.md`, `STATUS.md` | Each package should update the status of its rows | Edit only your own page tables in this file; leave `FORGE-PARITY.md` and `STATUS.md` to one integrator commit at the end. |
| `android/app/src/test/java/com/noop/ui/forge/` | Tests | One new test file per package, named after the package's new file. |

### 5.3 Order and checks

1. P0 skeleton commit (above), reviewed by the owner.
2. Packages 1 to 6 in parallel from that commit. Each states `Analysis migration required: yes/no` in every commit message and runs, before handing over: the package's `swift test` (core changes), `cd android && ./gradlew testFullDebugUnitTest --tests "com.noop.ui.forge.*"`, and `Tools/i18n_audit.py --ci`.
3. Per `AGENT_RULES.md`: commit as `DX23876 <176692557+DX23876@users.noreply.github.com>`, no AI trailer; run `Tools/local-tests.sh` once on the final tree; compile and look at the Android pages on a device or emulator. Compose changes are not verified by unit tests.
4. A page is done only when every iOS row in its table above is SAME, PLATFORM or an agreed, written exception (rule "finish every parity page"); update the Status column when it is.

### 5.4 Heads-up: work in flight in the main checkout

At the time of this inventory the main checkout (another branch) held uncommitted edits to
`Packages/NoopCoreJNI/Sources/NoopCore/CoreCall.swift`, `AndroidLocalizationShim.swift`,
`Packages/NoopCoreJNI/Tests/NoopCoreTests/CoreLocalizationTests.swift`, `android/app/src/main/java/com/noop/core/CoreShadow.kt`,
`android/app/src/main/java/com/noop/ui/AppLanguage.kt`, `android/app/src/test/java/com/noop/ui/AppLanguageTest.kt`,
the iOS side (`Strand/App/AppLanguage.swift`, `Strand/AI/CoachReplyLanguage.swift`, `StrandTests/`) and new
files `Packages/StrandCore/Sources/StrandCore/AppLanguageCatalog.swift`, `Tools/gen_app_languages.py`. That is an app-language
catalogue change. It overlaps `CoreCall.swift` and `CoreShadow.kt` (packages 1, 3, 5, 6 and P0) and `AppLanguage.kt` (LU-01,
which is why package 4 is told not to touch it). Merge or wait for it before P0.

### 5.5 Which package owns which open row

Every DIFFERENT and MISSING row of section 2 and the package that closes it (M = MISSING, D = DIFFERENT). SAME and PLATFORM rows need no work. Notes: H-06 and H-07 are the pages package 2 builds; package 6 changes the hub rows after the skeleton commit. LAB-02: package 6 adds the switch to Lab (same preference), package 5 removes the duplicate from Calculations in the same release. SUB-05 and SUB-09: package 2. DB-09 and SUB-04 are one job.

| Package | Open rows |
|---|---|
| 1 | PRO-01 (D), PRO-03 (D), PRO-06 (M), PRO-09 (D), PRO-11 (D), PRO-12 (M), PRO-13 (M), PRO-14 (D), PRO-15 (D), GOA-04 (D), TRA-04 (M), TRA-08 (M), TRA-19 (D), TRA-22 (D), TRA-24 (D), SUB-12 (D), SUB-13 (D) |
| 2 | H-06 (D), H-07 (D), S-01 (M), S-03 (D), S-05 (M), S-08 (D), S-09 (D), S-10 (D), S-11 (D), S-13 (D), S-14 (D), SUB-05 (D) |
| 3 | SA-01 (D), SA-04 (D), SA-05 (D), N-03 (D), N-04 (D), N-05 (D), N-06 (D), N-08 (D), N-09 (M) |
| 4 | LU-03 (M), AP-01 (M), AP-03 (D), AP-04 (D), AP-05 (M), AP-07 (M), AP-09 (M), BG-02 (M), BG-06 (M), BG-07 (M), CH-01 (M), CH-02 (M), CH-03 (M), MO-03 (M), MO-04 (M) |
| 5 | CAL-05 (M), CAL-06 (M), CAL-07 (M), CAL-08 (D), DB-04 (D), DB-09 (M), DB-10 (D), SUB-04 (M) |
| 6 | H-03 (D), H-08 (D), H-13 (D), H-14 (D), H-15 (D), H-16 (D), H-18 (M), CO-01 (D), CO-02 (D), CO-03 (D), CO-04 (M), HLP-06 (D), LAB-02 (D), LAB-07 (M), LAB-08 (D), SUB-10 (D), ABT-01 (D), ABT-02 (M), ABT-03 (D), ABT-06 (D), ABT-07 (D), ABT-09 (M), ABT-10 (M) |

---

## 6. String resources

**Android layout.** One resource file per locale, `android/app/src/main/res/values<-qualifier>/strings.xml`:

| Folder | Locale | Strings (approx.) |
|---|---|---|
| `values/` | English, the source | 7,215 strings, 51 plurals |
| `values-de/` | German | 7,207 |
| `values-es/` | Spanish | 7,208 |
| `values-fr/` | French | 7,208 |
| `values-it/` | Italian | 7,208 |
| `values-pl/` | Polish | 7,208 |
| `values-pt-rPT/` | Portuguese (Portugal) | 7,208 |
| `values-ru/` | Russian | 7,154 (behind the others) |
| `values-zh/` | Chinese | 7,208 |

Nine locales including English. The iOS catalogue ships the same set (en, de, es, fr, it, pl, pt-PT, ru, zh-Hans, zh-Hant); Android has
one `zh`. `docs/FORK_GUIDE.md` states the rule: never a narrower set than upstream.

**Key naming.** Forge screens: hand-named `forge_<area>_<slug>` (`forge_sg_*` goals settings, `forge_st_*` training settings,
`forge_ap_*` appearance, `forge_lab_*`, `forge_set_*` the new hub, `forge_settings_*` page titles and subtitles, `forge_backup_*`).
Strings carried over from the classic screens: `l10n_<screen>_<slug>_<hash8>` (a hash of the English text; reuse them
with `stringResource(R.string.…)` or `uiString(R.string.…)` instead of making new ones, for example
`l10n_settings_screen_this_is_a_plain_unencrypted_archive_b0dfe63d`). Others: `settings_*`, `power_saving_*`, `coach_*`,
`project_*`, `donation_*`, `nav_*`, `onboarding_*`. Plurals use `<plurals>` (51 today).
Forge composables use `stringResource`; classic ones use `uiString` (same resources).

**Where new strings go.** Base English in `values/strings.xml`; the same key in all eight other files. Packages use the
anchored blocks and key prefixes of section 5.2. Rules the audit enforces (`Tools/i18n_audit.py --ci`):
- no new hardcoded UI literal in Kotlin (`Text("…")`, `title = "…"`): the baseline `Tools/i18n_audit_baseline.json` only shrinks; many classic screens still carry old literals, do not copy that style;
- the focus locales `de, es, fr, pt-rPT, pl` must be complete (zero tolerance); `it, ru, zh` are ratcheted by `Tools/i18n_extra_locale_baseline.txt`, so a key missing there widens the gap and fails the ratchet: add all eight;
- positional placeholders `%1$s`, `%2$d` in anything with two or more arguments, same placeholders in every locale; apostrophes escaped (`\'`); no leading or trailing whitespace differences.

**Reuse iOS translations.** The iOS strings are in `Strand/Resources/Localizable.xcstrings` (11,394 keys; the key is the English text; locales
`de, es, fr, it, pl, pt-PT, ru, zh-Hans, zh-Hant`). For a row whose English text is identical on iOS (for example "Week starts", "Reduce motion"), copy the iOS
translation instead of translating again. German UI says "Strap" (der Strap), never Band or Armband; Polish is a separate JSON format on the iOS side only.
Existing Android Settings strings that already match an iOS row should be reused, not duplicated: grep `values/strings.xml` for the English text first.
