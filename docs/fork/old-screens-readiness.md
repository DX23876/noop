# The old screens: what they need before the new design becomes the default

Owner decision, 2026-11-15: the old screens keep their design. They stop being the main entry once the
new design (Forge) becomes the default, and they stay **fully usable** after that. This file is the
precondition list for flipping `ForgeDesignPrefs.defaultPreview` / `ForgeDesign.DEFAULT` to true. The
flip itself is a release event with its own testing round; nothing here flips it.

The bar, as agreed:

- **(a)** Every setting that only an old screen offers stays reachable from the new design's own
  settings hub.
- **(b)** Every card an old screen shows leads to a page that exists in the chosen design, never into
  nothing.
- A per-screen pass on every testing round is required for Today, Sleep, Training and Health only. With
  261 files under `Strand/Screens` a pass over all of them would exist on paper and nowhere else.

**Scope of this round:** the four Today styles, their own settings, and where their taps go. The other
old screens are a second round, deliberately not started here.

## What the setting actually does today

| | With the new design OFF | With the new design ON |
|---|---|---|
| Today tab | `todayTabRoot` switches on `TodayDashboardStyle`: Classic, Liquid, Trends, Overview (`StrandiOS/App/RootTabView.swift:109`) | `forgeTabView`, which draws `ForgeTodayView` and never reads the style (`RootTabView:278`) |
| The style picker | Settings › App › Today & Trends › Dashboard style | the same row, still there, and nothing happens |

**Finding 1 (the first thing to fix): the picker is reachable and mute.** It is not missing. It sits in
`SettingsPage.todayTrends` → section `.todayLayout` (`Strand/Screens/SettingsSearchCatalog.swift:163`,
`SettingsView.swift:3648`), which the new design's settings index lists in its "App" group
(`StrandiOS/Forge/ForgeSettingsView.swift`, `group("App", [...])`). So a wearer with the new design on can
choose Classic, Liquid or Trends and the screen will not change. A setting that is reachable and silent is
worse than one that is absent: it reports a choice nobody honoured. Either the new shell honours the style
for the Today tab, or the row says plainly that it applies to the old design only. Honouring it is what
"the old screens stay usable" means, so that is the direction.

## Per style

| Style | Screen | Its own settings | Reachable with the new design on |
|---|---|---|---|
| Classic | `Strand/Screens/TodayView.swift` | section order and hidden sections (`TodayLayoutPrefs`, `TodaySection`), edited in `TodayCustomizationSheet` | **No.** The sheet is opened only from the screen itself (`TodayView.swift:1786`) |
| Liquid | `Strand/Liquid/LiquidTodayView.swift` | the same `TodayLayoutPrefs`, same sheet (`LiquidTodayView.swift:971`) | **No**, same reason |
| Trends | `Strand/Screens/TrendsDashboardView.swift` | four metric slots (`trendsSlotPickers`) and the block editor (`DashboardLayoutPrefs`, key `"trends"`) | Through the Dashboard card, but **only while the stored style is Trends**: both the slot pickers and the editor row are conditional on it |
| Overview | `Strand/Screens/OverviewDashboardView.swift` | `OverviewHealthCardsPrefs`, `OverviewFocusPrefs`, and the block editor (key `"overview"`), plus edits on the screen | Same condition, with the stored style Overview |

**Finding 2: the Classic and Liquid arrangement has no door outside its own screen.** Both open
`TodayCustomizationSheet` from the screen, and no settings row does. With the new design on, a wearer who
had arranged Today cannot change that arrangement at all, and the new design's own tile editing writes a
different store (`forge.today.widgets`), so it is not the same arrangement either. Either the sheet gets a
settings row of its own, or the style setting starts working (finding 1) and the sheet is reachable through
the screen again.

**Finding 3: two arrangement systems, and it is easy to get them backwards.** `TodayLayoutPrefs`
(`TodaySection`) arranges Classic and Liquid. `DashboardLayoutPrefs` (`DashboardLayoutSection`) arranges
Trends and Overview, with its own per-style on/off state (`DashboardExtraSectionsPrefs.storageKey` takes
the dashboard as a prefix, deliberately, so an extra turned on for Trends does not appear in Overview).
Moving Overview's three blocks ("Today at a glance", "Today's focus", "Your health") into Liquid is
therefore three new `TodaySection` cases, not a new editor. Written down because the first version of this
note had it wrong in both directions.

**Finding 4: Overview is Apple-only from 2026-11-15.** Android dropped the style (it drew the same Forge
Today as Liquid); Apple keeps the screen. `Tools/test_android_ios_parity.py` carries that as
`STYLE_APPLE_ONLY` and fails if Android offers it again.

## Bar (b), the cards: not judged yet

The old screens push `TabRoute` destinations; the new shell resolves its own through
`forgeRouteDestinations`, and the one shared pattern is per route, for example
`case .energy: if NoopVisualStyle.skin == .forge { ForgeEnergyView() } else { EnergyDetailView() }`
(`RootTabView.swift:647`). While the new design cannot show an old dashboard at all (finding 1), there is
nothing to tap and nothing to judge. Bar (b) is therefore **open**, and it is the second half of fixing
finding 1: whichever way the style is honoured, every destination an old dashboard pushes must resolve in
the shell that is showing it.

## Appendix: #43's back path, traced in the source (2026-11-15)

Recorded because the trace came out empty, and the next person should not repeat it blind. The report
is "All settings with no way back"; the owner's own comment on the issue says the page sits on a stack
that handles the back gesture and the code does not show how it loses it. It still does not. What the
source does say:

- `ForgeSettings` (`ForgeSettings.kt:319`) keeps its own route stack in `rememberSaveable`, with
  `BackHandler(enabled = stack.isNotEmpty()) { pop() }` (line 331) and `pop()` at line 328.
- Both hubs carry the row and both push the same route: the old-design `Hub` through `onAll`
  (line 347, drawn at ~381) and `NewDesignHub` through `onSub(ForgeSettingsSub.AllSettings)`
  (line 453). Either way the stack was empty, so it becomes size 1.
- `AllSettings` is hosted as `Hosted(title, onBack) { SettingsScreen(…) }` (line 681). `Hosted`
  (line 507) does not draw the bar itself: it provides `LocalHostedChrome`, whose header slot draws
  `PageTitle(title ?: pageTitle, onBack, trailing)`, and `PageTitle` (line 459) draws the arrow
  unconditionally. `SettingsScreen` renders through `ScreenScaffold`, which takes the hosted branch and
  calls `hosted.header(...)` (`Components.kt:1352`). So the arrow is drawn, and `SettingsScreen` has no
  `BackHandler` of its own to swallow the gesture.
- The three entries differ in exactly one respect: `pop()` calls `onClose()` when
  `initialPage != null && stack.size == 1`. A sheet opened directly on a page closes on Back instead of
  showing the hub, which is intended ("Opened on one page … Back from it closes") but is also the one
  thing a wearer can reasonably describe as having no way back. That shape is reachable from More's
  profile row (`ForgeMore.kt:135`), from a More row (`ForgeMore.kt:140`) and from settings search, which
  closes the sheet and reopens More with the search focused (`ForgeRoot.kt:100`) so a result lands on a
  PAGE. It is not reachable for All settings itself, which is a `ForgeSettingsSub`, never an
  `initialPage`.

So the walk on an emulator should test the GESTURE and the arrow separately, in this order: open All
settings from the hub (expect: arrow back to the hub), from More's profile row then into All settings
(expect: arrow back one step, not out of settings), and from settings search (expect: the result page,
and Back leaving settings by design). Note which design is on: the old one draws `Hub`, the new one
`NewDesignHub`, and only one of them is what the reporter saw.

**The walk ran on 2026-11-15** (emulator `noop-spike`, android-35 arm64, demo debug build, the tree at
`5ef323b4d`). It does NOT reproduce, in either design:

| Entry | Arrow drawn | Arrow leads to | System Back leads to |
|---|---|---|---|
| New design, profile button → Settings → All settings | yes | the Settings index | the Settings index |
| New design, the same after `am kill` while All settings was open | yes, restored into the page | not retried | the Settings index |
| New design, settings search | — | — | "all settings" gives "No matches"; All settings is not a searchable page, and a page found by search (Appearance) returns to More on Back, by design |
| New design, More | — | — | More has no Settings row at all; its Tools category holds Breathe, Intervals and Live |
| Old design, More → Settings → All settings | yes | not retried | the Settings index |

So the third entry of the three in the report does not exist in the new design, and the two that do
both come back. Either one of the 34 commits since the tester's build closed it on the way (`f704b0e28`,
`567804133` and `9993665e5` all touched these screens), or it needs a state this walk did not reach, a
rotation or a specific gesture-navigation case among them. What would settle it is which row the
reporter came in through, and whether the arrow was missing or the gesture did nothing.

## What this round did not check

- The other old screens (Sleep, Training, Health, Workouts, Insights and the rest of `Strand/Screens`).
- Android's old screens (`com.noop.ui`, 163 files beside 111 under `com.noop.ui.forge`).
- Anything on a device or an emulator. Every line above was read from the source, and the mute-setting
  finding in particular should be confirmed by hand once before anybody acts on it.
