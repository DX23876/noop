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

## What this round did not check

- The other old screens (Sleep, Training, Health, Workouts, Insights and the rest of `Strand/Screens`).
- Android's old screens (`com.noop.ui`, 163 files beside 111 under `com.noop.ui.forge`).
- Anything on a device or an emulator. Every line above was read from the source, and the mute-setting
  finding in particular should be confirmed by hand once before anybody acts on it.
