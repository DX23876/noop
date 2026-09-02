#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    /// External entry points must wait until the mandatory first-run gates have completed. The root owns
    /// that state; keeping it explicit here prevents this shell's window-level sheet from covering a gate.
    let homeScreenQuickActionsEnabled: Bool

    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter
    /// The AI coach engine (injected at the app root), so the draggable floating Coach button can present
    /// the chat from the shell.
    @EnvironmentObject private var coach: AICoachEngine
    #if DEBUG
    @EnvironmentObject private var intelligence: IntelligenceEngine
    #endif

    /// Whether the draggable floating Coach button is one of the user's chosen entry points.
    @AppStorage(CoachEntryPrefs.floatingButtonKey) private var coachFloatingButtonEnabled = true
    /// Master switch (#R7): hides the floating Coach button when the coach UI is turned off.
    @AppStorage(CoachEntryPrefs.uiEnabledKey) private var coachUIEnabled = true
    /// Feature-level switch, independent of Today placement. A fresh installation keeps the Coach
    /// inactive until the person has chosen to enable it in More → AI Coach.
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @State private var showCoach = false
    /// The scene-local receiver for actions chosen from NOOP's Home Screen icon menu.
    @EnvironmentObject private var homeScreenQuickActions: HomeScreenQuickActionSceneDelegate

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// Live Sessions (silent guardian). Owned by the SHELL now, not by Today: the entry moved off the Today
    /// dashboard into the quick-action menu, and the guardian wants the full screen, so it presents as a
    /// cover here rather than as one of the `quickAction` sheets.
    @State private var showLiveSession = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// Selected tab — bound so tab switches can crossfade (README §Motion: ~240ms opacity swap
    /// between tab roots, calm easing). Defaults to Today.
    @State private var selectedTab: Int = 0
    /// One `NavigationPath` per tab, indexed by tab tag. Re-tapping the already-active tab pops
    /// that tab's stack to its root (#135) by clearing its path — an animated pop that leaves the
    /// root view alive, so an at-root re-tap keeps scroll position and never re-runs `.task`
    /// (#198; the #197 resetID/`.id()` rebuild reset both). Requires the tab roots' first-hop
    /// links to push `TabRoute`/`MoreDestination` VALUES — closure-destination links bypass the path.
    @State private var tabPaths: [NavigationPath] = Array(repeating: NavigationPath(), count: 4)
    /// One scroll-to-top token per tab. Bumped when the user re-taps the active tab while it's ALREADY
    /// at its root — the other half of the iOS convention #197/#198 left unserved (an at-root re-tap was
    /// a no-op). Threaded into each tab's root via `\.scrollToTopSignal`; ScreenScaffold / LiquidTodayView
    /// scroll to their top anchor when their tab's token changes.
    @State private var scrollTop: [Int] = Array(repeating: 0, count: 4)
    /// Which More-tab groups are expanded (S2). Insights + Body stay open at rest; Data + App collapse to
    /// just their header until tapped. Persisted (#860 item 2): the user's open/closed choice must SURVIVE
    /// leaving and re-entering the More tab (and relaunch), not reset to the seed every visit. Backed by an
    /// `@AppStorage` CSV string (keyed identically to the Android `MoreSectionPrefs`), bridged to a
    /// `Set<String>` through `MoreSectionPrefs` so the section logic below is unchanged.
    @AppStorage(MoreSectionPrefs.storageKey) private var expandedMoreSectionsCSV = MoreSectionPrefs.defaultCSV
    private var expandedMoreSections: Set<String> { MoreSectionPrefs.decode(expandedMoreSectionsCSV) }

    /// The More index's filter text. Deliberately NOT persisted: a search is a momentary question,
    /// and coming back to the tab to find it still filtered would read as the app having lost rows.
    @State private var moreQuery = ""
    /// Whitespace alone is not a search — it would blank the index for a stray space.
    private var isSearchingMore: Bool { !SearchMatch.tokens(moreQuery).isEmpty }

    /// V8 liquid redesign is the default Today; the Settings picker lets a user choose Classic, or
    /// either of the two reference-matched dashboards, instead (keyed identically to the SettingsView
    /// picker). Default Liquid.
    @AppStorage(TodayDashboardStyle.storageKey) private var todayDashboardStyleRaw = TodayDashboardStyle.liquid.rawValue
    private var todayDashboardStyle: TodayDashboardStyle {
        TodayDashboardStyle.resolve(todayDashboardStyleRaw) ?? .liquid
    }

    /// The Today tab root, honouring the chosen dashboard style.
    ///
    /// The Heute-screen redesign (StrandiOS/Redesign/) used to take priority here when its own
    /// `noop.heuteRedesignEnabled` flag was on — removed along with its Settings toggle, since the
    /// prototype never got past off-by-default/untested-on-a-real-strap. Its code is left in place,
    /// just unreached from here, so no persisted `true` from an earlier build can resurrect it.
    @ViewBuilder private var todayTabRoot: some View {
        switch todayDashboardStyle {
        case .classic:  TodayView()
        case .liquid:   LiquidTodayView()
        case .trends:   TrendsDashboardView()
        case .overview: OverviewDashboardView()
        }
    }

    /// Clear the selection indicator UIKit derives from the bar's tint. With NOOP's gold accent the
    /// native bar would otherwise fill a gold capsule behind the active icon; `.tint` should colour the
    /// icon and label, nothing behind them.
    ///
    /// Deliberately the ONLY override. The pre-merge fork code also called
    /// `configureWithOpaqueBackground` here — that would opt the bar out of iOS 26's Liquid Glass and
    /// leave it looking dated, which is the opposite of why this shell went back to the platform bar.
    init(homeScreenQuickActionsEnabled: Bool) {
        self.homeScreenQuickActionsEnabled = homeScreenQuickActionsEnabled
        let appearance = UITabBarAppearance()
        appearance.selectionIndicatorTintColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    /// Native tab selection binding. SwiftUI sends taps on the already-selected item through the
    /// setter, which lets the system tab bar retain the app's refresh / pop-to-root / scroll-to-top
    /// convention without placing a custom hit-testing layer over the platform bar.
    private var nativeTabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { tag in
                if tag == selectedTab {
                    reselectTab(tag)
                } else {
                    selectedTab = tag
                }
            }
        )
    }

    /// Re-tapping the active tab refreshes that page's data (2026-07-02) and, from a subpage, pops that
    /// tab's stack back to its root (#135) — an animated pop via the path, NOT a rebuild. At the root the
    /// pop is skipped, so scroll position survives and the refresh doesn't double with a re-run of the
    /// root's `.task` (#198).
    private func reselectTab(_ tag: Int) {
        Task { await repo.refresh() }
        if !tabPaths[tag].isEmpty {
            tabPaths[tag] = NavigationPath()   // on a subpage: animated pop back to the root
        } else {
            scrollTop[tag] += 1                // already at root: scroll to the top (#198 follow-up)
        }
    }

    /// The anywhere-swipe tab-switch drag (2026-07-02). Held as a property so the attachment site can
    /// enable or disable it through a `GestureMask` instead of attaching it conditionally: a conditional
    /// attachment changes view identity, and this condition toggles on every push and pop, which would
    /// rebuild the tab roots underneath it. The same class of rebuild is what #197 caused with an
    /// `.id()` reset and #198 had to undo — it lost scroll position and re-ran `.task`.
    ///
    /// Only a decisive horizontal flick switches tabs, and Today is carved out because it uses
    /// horizontal swipe to change DAYS. Both thresholds are unchanged from the original gesture.
    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                // Today (tab 0) uses horizontal swipe to change DAYS, so tab-swipe is off there.
                guard selectedTab != 0 else { return }
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.6 else { return }
                let next = min(3, max(0, selectedTab + (dx < 0 ? 1 : -1)))
                if next != selectedTab {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = next }
                }
            }
    }

    var body: some View {
        // The platform tab bar drives navigation. NOOP drew its own floating bar for one reason — a
        // native TabView can't host a centre item that overflows the bar, and the signature gold FAB
        // sat there. That FAB has since moved to the top-right of each screen's header, which left a
        // custom bar doing exactly what the native one does, minus the system's safe-area handling,
        // Dynamic Type and (on iOS 26) Liquid Glass. Reverting to native also stops this shell
        // diverging from upstream, which is where the duplicated-bar merge damage came from.
        //
        // The ZStack stays for the draggable CoachFloatingButton below, which still floats over
        // every tab.
        ZStack(alignment: .bottom) {
            TabView(selection: nativeTabSelection) {
                tab(todayTabRoot, "Today", "square.grid.2x2", path: $tabPaths[0], scrollSignal: scrollTop[0]).tag(0)
                tab(TrendsView(), "Trends", "chart.line.uptrend.xyaxis", path: $tabPaths[1], scrollSignal: scrollTop[1]).tag(1)
                tab(SleepView(), "Sleep", "bed.double", path: $tabPaths[2], scrollSignal: scrollTop[2]).tag(2)
                moreTab(path: $tabPaths[3], scrollSignal: scrollTop[3]).tag(3)
            }
            // Overview Dashboard mockup fidelity (2026-08-31): the active tab reads green, not the
            // configurable Accent colour. `.tint()` colours the whole bar uniformly — there is no native
            // per-tab-item override — so this is deliberately a global change across all four tabs.
            .tint(StrandPalette.chargeColor)
            // Tab crossfade — README §Motion: ~240ms opacity swap between tab roots, global calm
            // easing cubic-bezier(0.22,1,0.36,1).
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
            // Swipe left/right anywhere to move between tabs (2026-07-02), but ONLY while the current
            // tab is at its root. Attaching this ancestor drag gesture unconditionally defeated the
            // edge-restriction of a pushed NavigationStack screen's native interactive-pop gesture —
            // any More-tab subscreen (Settings, Devices, …) became draggable/rubber-banding from
            // anywhere, not just the left edge (#519). Disabling the recognizer once a push is active,
            // rather than just gating the onEnded action, is what stops the interference: the action
            // never runs early enough, because the recognizer competes during recognition.
            //
            // The mask does that WITHOUT changing view identity. #519 attached the gesture through a
            // conditional ViewModifier, which put the two states in separate _ConditionalContent
            // branches — and since this condition toggles on every push and pop, each navigation
            // rebuilt the whole TabView subtree and could reset @State inside the tab roots (scroll
            // offsets, chart ranges, expanded sections). `including:` keeps one view type in both
            // states, so nothing is torn down.
            //
            // The mask MUST be `.subviews`, not `.none`. `.subviews` means "enable the subview
            // hierarchy's gestures, disable the added one" — exactly this requirement. `.none` disables
            // the subview hierarchy TOO, which on a pushed screen would take out scrolling, taps and the
            // interactive-pop itself: far worse than the bug being fixed.
            .simultaneousGesture(tabSwipeGesture,
                                 including: tabPaths[selectedTab].isEmpty ? .all : .subviews)

            // Draggable floating Coach button — an alternative entry to the Today banner, honouring the
            // user's Coach-entry preference. Floats over every tab; a tap opens the chat.
            if coachFeatureEnabled, coachUIEnabled, coachFloatingButtonEnabled {
                CoachFloatingButton(isPresented: $showCoach)
            }
        }
        .coachCover(isPresented: $showCoach, coach: coach)
        .task {
            // Backup & Sync: on-launch catch-up (see RootView). Detached + utility priority so a
            // 100MB+ whole-DB ZIP never blocks startup; gated on the auto toggle (default OFF). (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        // Quick-action sheet presents with the calm easing (~0.42s) per the README sheet spec —
        // the easing is applied where `quickAction` is set (see `presentQuickAction`), keeping the
        // animation scoped to the sheet rather than the whole shell.
        .sheet(item: $quickAction) { action in
            quickActionDestination(action)
        }
        // Live's "Manage devices" affordance (and any future cross-screen link to Devices) routes here:
        // present the Devices manager in its own nav stack, the same way the quick-action screens do.
        .sheet(isPresented: $showDevices) {
            devicesScreen
        }
        // Live Sessions: a full-screen cover (the guardian owns the display mid-session), presented from
        // the quick-action menu or a coach deep-link. Same helper the macOS Today row uses.
        .liveSessionCover(isPresented: $showLiveSession)
        // v5 pillar deep-links (Insights hub / Lab Book / fused record / Rhythm) present as a sheet in
        // their own nav stack — the same idiom the quick-action + Devices screens use on iPhone.
        .sheet(item: $routedPillar) { dest in
            pillarScreen(dest)
        }
        // Honour a router request: Devices keeps its dedicated sheet; the v5 pillars route through the
        // shared pillar sheet. Cleared so the same tap can fire again later.
        .onChange(of: router.requestedDestination) { _, dest in
            switch dest {
            case .devices:
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm:
                routedPillar = dest
                router.requestedDestination = nil
            case .trends:
                // Trends is a primary tab on iPhone (not a pillar sheet) — switch to it.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
                router.requestedDestination = nil
            case .sleep:
                // Sleep is a primary tab too. Raised by the morning card's "Fix it" when last night's
                // wake time looks truncated, so the editor is one tap away rather than a hunt.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 2 }
                router.requestedDestination = nil
            case .energy:
                // Widget deep link: land on Today and push the same detail route the in-app card uses.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                tabPaths[0] = NavigationPath([TabRoute.energy])
                router.requestedDestination = nil
            case .activeWorkout:
                // The Today active-workout indicator opens Live through the quick-action Live sheet; once
                // it's up, LiveView consumes the one-shot `presentActiveWorkout` flag and presents the
                // in-exercise screen. Calm sheet easing, matching the other quick-action presents.
                withAnimation(Self.sheetEase) { quickAction = .live }
                router.requestedDestination = nil
            case .liveSession:
                // The Start entry no longer lives on Today (it moved into the quick-action menu), so a
                // deep-link presents the session cover straight from the shell instead of switching tabs
                // and hoping the user finds a card. Mirrors how `.breathe` skips the menu step below.
                showLiveSession = true
                router.requestedDestination = nil
            case .breathe:
                // Reuses the SAME quick-action sheet machinery `.activeWorkout` does for `.live` — the
                // coach chat's action row asks for Breathe directly, skipping the quick-action MENU step.
                withAnimation(Self.sheetEase) { quickAction = .breathe }
                router.requestedDestination = nil
            case .journal:
                // The #627 Today journal widget opens the journal through the quick-action Journal sheet
                // (InsightsView), matching the FAB's "Log journal" action. Calm sheet easing.
                withAnimation(Self.sheetEase) { quickAction = .journal }
                router.requestedDestination = nil
            case .dataSources:
                // Raised by the empty states' "Open Data Sources" button. Pushed onto the More tab's
                // own stack — the same MoreDestination the More row uses — so Back returns the reader
                // to where they were rather than stranding them in a tab they did not choose.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 3 }
                // Appended rather than assigned (the Coach deep links REPLACE the More stack): if the
                // reader was already somewhere under More, Back should return them there instead of
                // dropping them at the index. From any other tab the stack is at its root, so this
                // behaves exactly like a replace.
                tabPaths[3].append(MoreDestination.dataSources)
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        // Daily coach check-in tapped (NOOP AI): jump to the More tab and open Coach on top of it.
        // CoachView refreshes the brief itself — it observes the same event.
        .onReceive(NotificationCenter.default.publisher(for: .noopOpenCoachCheckIn)) { _ in
            guard coachFeatureEnabled else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 3 }
            tabPaths[3] = NavigationPath([MoreDestination.coach])
        }
        // "Ask coach" tapped on a metric card (#P11): same jump — open Coach on top of the More tab; it
        // reads the pending card context and gives a short read of that metric.
        .onReceive(NotificationCenter.default.publisher(for: .noopOpenCoachCard)) { _ in
            guard coachFeatureEnabled else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 3 }
            tabPaths[3] = NavigationPath([MoreDestination.coach])
        }
        .onChange(of: coachFeatureEnabled) { enabled in
            // A cover can remain on screen while the switch is changed from a second window or a
            // Settings deep link. Close it immediately so "off" really means no visible Coach UI.
            if !enabled { showCoach = false }
        }
        // A screen's top-bar "+" routes here: open the quick-action sheet, then clear the flag.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                withAnimation(Self.sheetEase) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
        // A cold-launch selection is already pending when this shell appears; a warm selection arrives
        // through the change callback. Both route through the same screens as the centre FAB.
        .onAppear {
            presentPendingHomeScreenQuickActionIfPossible()
        }
        .onChange(of: homeScreenQuickActions.pendingAction) { _, _ in
            presentPendingHomeScreenQuickActionIfPossible()
        }
        .onChange(of: homeScreenQuickActionsEnabled) { _, _ in
            presentPendingHomeScreenQuickActionIfPossible()
        }
    }

    /// Mandatory launch gates defer an external action. Once the shell is available, an explicit Home
    /// Screen choice supersedes any ordinary shell sheet; choosing the already-open destination simply
    /// consumes the request and leaves that screen in place.
    private func presentPendingHomeScreenQuickActionIfPossible() {
        guard homeScreenQuickActionsEnabled,
              let action = homeScreenQuickActions.pendingAction else { return }

        let destination: QuickAction = switch action {
        case .liveHeartRate: .live
        case .startWorkout: .workout
        case .logJournal: .journal
        case .breathe: .breathe
        }
        homeScreenQuickActions.consume(action)
        withAnimation(Self.sheetEase) {
            showDevices = false
            routedPillar = nil
            quickAction = destination
        }
    }

    /// A routed v5 pillar screen wrapped in its own nav stack + Done button (mirrors `quickScreen`).
    @ViewBuilder
    private func pillarScreen(_ dest: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch dest {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                // .trends is never presented as a pillar sheet on iPhone (it's a primary tab — the
                // requestedDestination handler switches `selectedTab` instead), but the switch must stay
                // exhaustive. Fall back to Trends inside the sheet host if it ever arrives here.
                case .trends: TrendsView()
                // .activeWorkout routes through the quick-action Live sheet (handled above); this keeps the
                // switch exhaustive and falls back to Live if it ever reaches the pillar host.
                case .activeWorkout: LiveView()
                // .liveSession routes to the Today tab (handled above — its Start entry owns the cover);
                // this keeps the switch exhaustive and falls back to Today if it ever reaches the host.
                case .liveSession: LiquidTodayView()
                // .breathe routes through the quick-action sheet (handled above); this keeps the switch
                // exhaustive and falls back to BreathingView directly if it ever reaches the host.
                case .breathe: BreathingView()
                // .journal opens through the quick-action Journal sheet (handled above); this keeps the
                // switch exhaustive and falls back to the journal's Insights host if it ever reaches here.
                case .journal: InsightsView()
                // .dataSources is pushed onto the More tab's own stack (handled above); this keeps the
                // switch exhaustive and falls back to the screen itself if it ever reaches the host.
                case .dataSources: DataSourcesView()
                // .sleep switches to the Sleep tab (handled above); this keeps the switch exhaustive and
                // falls back to the screen itself if it ever reaches the host.
                case .sleep: SleepView()
                // .energy is pushed onto Today's own stack (handled above); this fallback keeps the
                // sheet host exhaustive if the destination is ever presented here directly.
                case .energy: EnergyDetailView()
                }
            }
            // The Trends/Today fallbacks above emit TabRoute value pushes (#198), which need a
            // destination registered in THIS sheet's stack to resolve.
            .tabRouteDestinations()
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // #1027: same fix as quickScreen — the pillar screens draw the full-bleed liquid sky, so a
            // transparent nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    /// Calm-easing curve (cubic-bezier(0.22,1,0.36,1)) at the README sheet-present duration.
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: - Quick-action sheet

    /// Routes a chosen quick action to the existing screen, or shows the action menu itself.
    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                // Swap the menu for the chosen destination on the next runloop so the sheet
                // re-presents cleanly (avoids dismiss/re-present races). Calm easing on re-present.
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // The guardian is a full-screen cover, not one of the sheet destinations — route it to
                    // its own presentation flag rather than back through `quickAction`.
                    if picked == .liveSession { showLiveSession = true }
                    else { withAnimation(Self.sheetEase) { quickAction = picked } }
                }
            }
            .presentationDetents([.height(416)])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(InsightsView())
        case .breathe:
            quickScreen(BreathingView())
        case .liveSession:
            // Never reached: the picker routes the guardian to `showLiveSession` (a full-screen cover), so
            // this arm only keeps the switch exhaustive.
            EmptyView()
        }
    }

    /// Wraps a routed quick-action screen in its own nav stack so it has a title bar + the
    /// shared surface background, matching how the More-tab links present these same views.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: these screens draw a full-bleed liquid sky (ScreenScaffold topBackground) that runs
                // edge-to-edge under a transparent bar — exactly how the tab roots present it. An OPAQUE
                // surfaceBase toolbar background sat on top of that sky and, as the content scrolled up, its
                // extended status-bar band CLIPPED the sky + the in-content header ("Live Body Console").
                // Hiding the bar background lets the sky stay continuous under the floating Done button.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    /// The Devices manager wrapped in its own nav stack + Done button (mirrors `quickScreen`, but
    /// dismisses the dedicated `showDevices` sheet rather than the quick-action item).
    private var devicesScreen: some View {
        NavigationStack {
            DevicesView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: same fix as quickScreen — Devices draws the full-bleed liquid sky, so a transparent
                // nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showDevices = false }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String,
                              path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        // Each primary tab gets its OWN NavigationStack so the in-content NavigationLinks (e.g. the Today
        // dashboard card rows) both navigate AND render opaque. An ORPHANED NavigationLink (no
        // NavigationStack ancestor) renders its whole label in a disabled/translucent state — that was
        // washing the Today cards over the hero scene and dimming their text to grey (2026-06-23).
        // The root view hides the system nav bar (each screen draws its own in-content header); pushed
        // detail screens get their own nav bar + back button. The stack is bound to the tab's path so a
        // re-tap of the active tab can pop it to the root (#135/#198); the roots' first-hop links push
        // TabRoute values, registered here ONCE per stack (a double registration double-pushes, #38).
        NavigationStack(path: path) {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .tabRouteDestinations()
        }
        // Drive this tab's root scroll-to-top on an at-root re-tap (#198 follow-up); read by ScreenScaffold
        // / LiquidTodayView inside. Only THIS tab's token changes on its reselect, so the others don't scroll.
        .environment(\.scrollToTopSignal, scrollSignal)
        .tabItem { Label(title, systemImage: icon) }
    }

    // The "More" tab is the app's catch-all index. It was a plain SwiftUI `List` with system large-title
    // + system title-case section headers, so it didn't match any other page (which all use ScreenScaffold
    // + SectionHeader's UPPERCASE overline + the 28pt section rhythm). Rebuilt on the shared page chrome:
    // ScreenScaffold for the title1 "More" + subtitle, a `SectionHeader` overline per group, and the group's
    // rows in a single grouped NoopCard with hairline dividers — the same row idiom Settings/Health use.
    private func moreTab(path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        NavigationStack(path: path) {
            ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                           onRefresh: { await repo.refresh() },
                           topBackground: liquidScaffoldSky()) {
                // The index is a lot of rows across four groups, two of which rest collapsed — so the
                // field comes FIRST, before the reader has to decide which group a screen lives in.
                // It also reaches into Settings (see `moreSearchResults`), which is where "where do I
                // turn X on?" actually ends.
                NoopLiquidGlassSearchField(
                    text: $moreQuery,
                    prompt: String(localized: "Search screens and settings"),
                    accessibilityLabel: String(localized: "Search screens and settings")
                )

                if isSearchingMore {
                    moreSearchResults
                } else {
                    // The rows themselves live in `MoreCatalog` — the search has to read them, and a
                    // @ViewBuilder closure cannot be read. Group order, titles and the persisted
                    // open/closed state are unchanged.
                    ForEach(MoreCatalog.groups) { group in
                        moreSection(group)
                    }
                }
            }
            // The rows push MoreDestination VALUES so a re-tap of the More tab can pop them off the
            // bound path (#135/#198). Each destination keeps the per-screen wrapper the rows used to
            // apply inline (surfaceBase background, inline title bar, hidden bar background):
            // #1027 — a pushed sky-scaffold screen (Live, Workouts, Health, …) draws a full-bleed liquid
            // sky; an opaque surfaceBase nav-bar band sat over it and clipped the top on scroll. A hidden
            // bar background keeps the sky edge-to-edge. On the flat (no-sky) screens this is visually
            // identical at rest — the destination's own surfaceBase background shows through the bar.
            .navigationDestination(for: MoreDestination.self) { route in
                route.destination
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
        }
        // Scroll the More index to the top on an at-root re-tap (#198 follow-up); read by its ScreenScaffold.
        .environment(\.scrollToTopSignal, scrollSignal)
        .tabItem { Label("More", systemImage: "ellipsis") }
    }

    /// One titled, COLLAPSIBLE group in the More index (S2): the app's overline (UPPERCASE) becomes a
    /// tappable header with a disclosure chevron; tapping it expands/collapses the grouped rows card.
    /// Insights + Body default open, Data + App default collapsed (the `expandedMoreSections` seed) so the
    /// list is shorter at rest without dropping a single row. The grouped card is unchanged: a single
    /// `NoopCard` holding a `VStack(spacing: 0)` whose `MoreRow`s draw their own hairlines, clipped to the
    /// card's rounded shape so the last divider is trimmed inside the corners. Same idiom Settings/Health use.
    @ViewBuilder
    private func moreSection(_ group: MoreGroup) -> some View {
        let title = group.title
        let isOpen = expandedMoreSections.contains(title)
        VStack(alignment: .leading, spacing: 10) {
            // Tappable overline header: the same ALL-CAPS tracked label as before, now with a trailing
            // chevron that rotates open. A plain Button (not a SwiftUI DisclosureGroup) so the header keeps
            // the exact strandOverline styling and the card layout below stays identical to before.
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    // Persist the toggle via the CSV-backed @AppStorage so the choice survives leaving and
                    // re-entering the More tab and relaunch (#860 item 2). MoreSectionPrefs owns encode/decode.
                    var open = expandedMoreSections
                    if isOpen { open.remove(title) } else { open.insert(title) }
                    expandedMoreSectionsCSV = MoreSectionPrefs.encode(open)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title).strandOverline()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed")))
            .accessibilityHint(Text(isOpen ? String(localized: "Double tap to collapse") : String(localized: "Double tap to expand")))

            if isOpen {
                // Zero internal padding so each MoreRow owns its own comfortable insets + height; the rows
                // supply their own hairline separators (drawn at the bottom of every row but the last via the
                // divider overlay) so the group reads as one continuous grouped list, matching Settings/Health.
                NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                    VStack(spacing: 0) {
                        ForEach(group.entries) { entry in MoreRow(entry) }
                    }
                        // Clip the rows column to the card's rounded shape so the last row's bottom hairline is
                        // trimmed inside the corners (the card draws its surface in the BACKGROUND and doesn't
                        // clip content itself, so without this the final divider would run past the rounded edge).
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
                }
            }
        }
    }

    /// The flat result list shown while the field has text.
    ///
    /// Flat on purpose: the groups (and their collapsed state) are exactly what the search exists to
    /// bypass — a hit hiding inside a closed "Data" group would be the bug this feature is meant to
    /// fix. Screens come first, then Settings sections, each labelled so a hit's home is never a guess.
    @ViewBuilder
    private var moreSearchResults: some View {
        let screens = MoreCatalog.matching(moreQuery)
        let settings = SettingsSearchCatalog.matching(moreQuery)

        if screens.isEmpty && settings.isEmpty {
            // An honest dead end rather than a blank screen. No "did you mean" — the matcher is
            // deliberately not fuzzy, so there is nothing truthful to suggest.
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing matches “\(moreQuery)”.")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Try a shorter word, or the name of the screen you're after.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
        } else {
            if !screens.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Screens").strandOverline()
                    NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                        VStack(spacing: 0) {
                            ForEach(screens) { entry in MoreRow(entry) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
                    }
                }
            }
            if !settings.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Settings").strandOverline()
                    NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                        VStack(spacing: 0) {
                            ForEach(settings) { entry in
                                // Carry the query into Settings so the pushed screen opens already
                                // filtered to this section — otherwise the tap would land the reader
                                // back in the same 15-card wall they were searching to avoid.
                                MoreRow(entry.title, "gearshape.fill", .settingsSearch(moreQuery),
                                        caption: "in Settings", colorKey: "settings")
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
                    }
                }
            }
        }
    }
}

/// Every screen the More index links to, as a `Hashable` value the tab's `NavigationPath` can carry
/// (#198): a closure-destination push would bypass the path and be un-poppable on tab re-tap. The
/// per-screen chrome the old inline links applied lives at the single `navigationDestination(for:)`
/// registration in `moreTab`.
enum MoreDestination: Hashable {
    case momentum
    case insightsHub, intelligence, coach, coachSettings, goalJourney, insights, explore, compare
    case live, workouts, health, labBook, stress, breathe, intervals, rhythm
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport, noopLimitations
    case alarms, automations, testCentre, siriShortcuts, powerSaving, settings
    /// Settings opened from a search hit, carrying the query so the screen lands already filtered to
    /// the matching section. Distinct from `.settings` (the plain row) so an ordinary tap on the
    /// Settings row still opens the whole screen.
    case settingsSearch(String)

    @ViewBuilder var destination: some View {
        switch self {
        case .momentum:        MomentumScreen()
        case .insightsHub:     InsightsHubView()
        case .intelligence:    IntelligenceView()
        case .coach:           CoachView()
        // More already owns the bound NavigationStack. Reuse it so opening Coach settings performs one
        // path update, not a nested NavigationAuthority update that poisons every later More-row tap.
        case .coachSettings:   CoachSettingsView(usesHostNavigation: true)
        case .goalJourney:     CoachGoalJourneyScreen()
        case .insights:        InsightsView()
        case .explore:         MetricExplorerView()
        case .compare:         CompareView()
        case .live:            LiveView()
        case .workouts:        WorkoutsView()
        case .health:          HealthView()
        case .labBook:         LabBookView()
        case .stress:          StressView()
        case .breathe:         BreathingView()
        case .intervals:       IntervalTimerView()
        case .rhythm:          RhythmHost()
        case .fusedRecord:     FusedRecordHost()
        case .appleHealth:     AppleHealthView()
        case .miBand:          XiaomiBandView()
        case .dataSources:     DataSourcesView()
        case .noopLimitations: NoopLimitationsView()
        case .backupSync:      BackupSyncView()
        case .shortcutsExport: ShortcutExportSettingsView()
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .testCentre:      TestCentreView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        case .powerSaving:     PowerSavingView()
        case .settings:        SettingsView()
        case .settingsSearch(let query): SettingsView(searchSeed: query)
        }
    }
}


/// One tappable destination row in the More index. A `NavigationLink` whose label is the standard app row:
/// the SF Symbol in its semantic Apple-inspired colour tile, the title in the body text colour, a `Spacer`, and a
/// trailing `chevron.right` in `textTertiary`. ~44pt min height + the card's row insets keep the whole row a
/// comfortable tap target.
struct MoreRow: View {
    let title: LocalizedStringResource
    let icon: String
    let route: MoreDestination
    /// Secondary line under the title. Only the search results use it — to say WHERE a hit lives
    /// ("in Settings"), which a flat result list otherwise leaves the reader to guess.
    var caption: LocalizedStringResource?
    /// Key for the semantic icon colour. Defaults to the route's own name, which is what every
    /// grouped row uses; a search result whose route carries an associated value (`.settingsSearch`)
    /// passes the plain key so it keeps the Settings colour instead of falling off the lookup.
    var colorKey: String?

    init(_ entry: MoreEntry) {
        self.init(entry.title, entry.icon, entry.route)
    }

    init(_ title: LocalizedStringResource,
         _ icon: String,
         _ route: MoreDestination,
         caption: LocalizedStringResource? = nil,
         colorKey: String? = nil) {
        self.title = title; self.icon = icon; self.route = route
        self.caption = caption; self.colorKey = colorKey
    }

    var body: some View {
        // Every More row must push through the NavigationStack's bound path. A closure-based special
        // case for Coach Settings bypassed `tabPaths[3]`; after popping it, SwiftUI's internal stack and
        // the binding disagreed, so later value links (Workouts, Health, Biomarkers, …) were ignored.
        NavigationLink(value: route) {
            rowLabel
        }
        .buttonStyle(.plain)
    }

    private var rowLabel: some View {
            HStack(spacing: 14) {
                // Pin the semantic colour directly. A plain inherited tint gets re-resolved by iOS to its
                // default blue a beat after first render — so the icons flashed green→blue (#184). The
                // shared tile owns both the stable fill and white glyph; the title remains neutral.
                Image(systemName: icon)
                    .appleInspiredMenuIcon(colorKey ?? String(describing: route))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let caption {
                        Text(caption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Hairline under every row; the grouped container clips the last one's overflow so the bottom
            // edge stays clean (the divider sits inside the card's rounded corners).
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }
// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe, liveSession
    var id: Int { rawValue }
}

/// The bottom sheet of quick actions presented by the centre FAB. Spec bottom sheet: surfaceOverlay
/// fill, gold hairline top edge, grab handle, three flat action rows that route to existing screens.
private struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
    let onPick: (QuickAction) -> Void

    /// Live Sessions (silent guardian) beta gate — the SAME key Settings and the macOS Today row read.
    /// Off removes the row entirely, exactly as it used to remove the Today Start-session entry.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    @AppStorage(AppleInspiredColorsPrefs.enabledKey)
    private var appleInspiredColors = AppleInspiredColorsPrefs.defaultEnabled

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle (36×4) in the slate hairline tone.
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("QUICK ACTIONS")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                row("Live HR", icon: "waveform.path.ecg", tint: StrandPalette.metricRose) { onPick(.live) }
                row("Start workout", icon: "figure.run", tint: StrandPalette.effortColor) { onPick(.workout) }
                row("Log journal", icon: "square.and.pencil",
                    tint: AppleInspiredColors.color(for: "journal", enabled: appleInspiredColors)) { onPick(.journal) }
                row("Breathe", icon: "wind", tint: StrandPalette.restColor) { onPick(.breathe) }
                if liveSessionsBeta {
                    // A Live Session is NOT a breathing exercise — it is quiet strap coaching against
                    // today's Charge — so it carries a subtitle here. Sitting one row under "Breathe"
                    // without one, the two would read as duplicates of each other.
                    row("Silent Guardian", icon: "shield.lefthalf.filled", tint: StrandPalette.metricCyan,
                        subtitle: "Quiet strap coaching against today's Charge") { onPick(.liveSession) }
                }
            }
            .padding(.horizontal, NoopMetrics.screenHPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            NoopChromeSurface()
                .overlay(alignment: .top) {
                    // Gold hairline top edge per the bottom-sheet spec.
                    Rectangle()
                        .fill(StrandPalette.gold.opacity(0.35))
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
    }

    /// One flat action row: hued line-icon tile + title, inset surface, hairline border. `subtitle` is for
    /// the rare row whose title alone can be mistaken for a neighbour's (see Silent Guardian vs Breathe).
    private func row(_ title: LocalizedStringKey, icon: String, tint: Color,
                     subtitle: LocalizedStringKey? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(NoopPanelSurface(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


#endif
