#if os(iOS)
import SwiftUI
import Combine
import UIKit
import StrandDesign
import WhoopStore

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    /// #1841: shared with Android by NAME and meaning, not by storage — the two platforms keep their own
    /// stores, exactly as the Clock format setting does.
    ///
    /// Default FALSE here while Android defaults true, and the divergence is deliberate. Apple's forums
    /// report `.tabBarMinimizeBehavior(.onScrollDown)` failing to trigger in tabs built on
    /// `NavigationStack(path:)` — which is every primary tab in this file, bound deliberately so a tab
    /// root can pop and re-scroll. So this may well be inert on our structure, and defaulting ON would
    /// advertise a behaviour that never happens. Off until someone confirms it on an iOS 26 device.
    @AppStorage("noop.bottomBarAutoHide") private var bottomBarAutoHide = false

    /// External entry points must wait until the mandatory first-run gates have completed. The root owns
    /// that state; keeping it explicit here prevents this shell's window-level sheet from covering a gate.
    let homeScreenQuickActionsEnabled: Bool

    /// Stable service reference supplied by the app host. Keeping it as a plain reference is deliberate:
    /// this shell only invokes Repository/Coach actions and must not re-evaluate the complete TabView when
    /// either object publishes an unrelated value. Screens below still observe the exact stores they use.
    let model: AppModel
    private var repo: Repository { model.repo }
    private var session: ActiveSessionController { model.session }
    private var coach: AICoachEngine { model.coach }
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter

    /// Whether the draggable floating Coach button is one of the user's chosen entry points.
    @AppStorage(CoachEntryPrefs.floatingButtonKey) private var coachFloatingButtonEnabled = true
    /// Master switch (#R7): hides the floating Coach button when the coach UI is turned off.
    @AppStorage(CoachEntryPrefs.uiEnabledKey) private var coachUIEnabled = true
    /// Feature-level switch, independent of Today placement. A fresh installation keeps the Coach
    /// inactive until the person has chosen to enable it in More → AI Coach.
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    @State private var showCoach = false
    /// The redesign preview (Settings › Lab). Off by default; `--new-design` turns it on in DEBUG runs.
    @AppStorage(ForgeDesignPrefs.previewKey) private var forgePreviewStored = ForgeDesignPrefs.defaultPreview
    private var forgeDesign: Bool { forgePreviewStored || ForgeDesignPrefs.launchOverride }
    /// The redesign has no More tab: the profile button opens the same index, with its own stack, as a sheet.
    @State private var showAllFeatures = false
    /// A question from an "Ask the coach" entry waiting for the inline data-sharing answer.
    @State private var pendingAsk: String?
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
    @State private var customizeTodayAfterDismissal = false
    /// One `NavigationPath` per tab, indexed by tab tag. Re-tapping the already-active tab pops
    /// that tab's stack to its root (#135) by clearing its path — an animated pop that leaves the
    /// root view alive, so an at-root re-tap keeps scroll position and never re-runs `.task`
    /// (#198; the #197 resetID/`.id()` rebuild reset both). Requires the tab roots' first-hop
    /// links to push `TabRoute`/`MoreDestination` VALUES — closure-destination links bypass the path.
    @State private var tabPaths: [NavigationPath] = Array(repeating: NavigationPath(), count: 5)
    /// One scroll-to-top token per tab. Bumped when the user re-taps the active tab while it's ALREADY
    /// at its root — the other half of the iOS convention #197/#198 left unserved (an at-root re-tap was
    /// a no-op). Threaded into each tab's root via `\.scrollToTopSignal`; ScreenScaffold / LiquidTodayView
    /// scroll to their top anchor when their tab's token changes.
    @State private var scrollTop: [Int] = Array(repeating: 0, count: 5)
    /// The More index's filter text. Deliberately NOT persisted: a search is a momentary question,
    /// and coming back to the tab to find it still filtered would read as the app having lost rows.
    @State private var moreQuery = ""
    /// The More search field's focus, released whenever the stack navigates, so a result opened from the search
    /// does not keep the keyboard up over the page it opened.
    @FocusState private var moreSearchFocused: Bool
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
    /// The Heute-screen redesign prototype used to take priority here when its own
    /// `noop.heuteRedesignEnabled` flag was on. The flag is no longer read and the prototype was deleted
    /// on 2026-10-10, so no persisted `true` from an earlier build can resurrect it.
    ///
    /// Every style carries the same `AnalysisUpdateBanner` at its foot while an analysis migration runs.
    @ViewBuilder private var todayTabRoot: some View {
        Group {
            switch todayDashboardStyle {
            case .classic:  TodayView()
            case .liquid:   LiquidTodayView()
            case .trends:   TrendsDashboardView()
            case .overview: OverviewDashboardView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { AnalysisUpdateBanner() }
    }

    /// Clear the selection indicator UIKit derives from the bar's tint. With NOOP's gold accent the
    /// native bar would otherwise fill a gold capsule behind the active icon; `.tint` should colour the
    /// icon and label, nothing behind them.
    ///
    /// Deliberately the ONLY override. The pre-merge fork code also called
    /// `configureWithOpaqueBackground` here — that would opt the bar out of iOS 26's Liquid Glass and
    /// leave it looking dated, which is the opposite of why this shell went back to the platform bar.
    init(model: AppModel, homeScreenQuickActionsEnabled: Bool) {
        self.model = model
        self.homeScreenQuickActionsEnabled = homeScreenQuickActionsEnabled
        #if DEBUG
        // Analysis migration required: no. This DEBUG-only selector opens an existing tab for
        // deterministic screenshots and does not affect production navigation or derived values.
        let args = CommandLine.arguments
        ForgeTodayWidgetStore.shared.seedDemoIfRequested()
        if let i = args.firstIndex(of: "--demo-tab"), i + 1 < args.count {
            let demoTabs = ["today": 0, "trends": 1, "health": 1, "training": 2, "sleep": 3, "more": 4]
            if let tab = demoTabs[args[i + 1].lowercased()] {
                _selectedTab = State(initialValue: tab)
            }
        }
        // Same for the redesign's pushed pages and sheets, which the board comparison captures one by one.
        if let i = args.firstIndex(of: "--demo-route"), i + 1 < args.count {
            // Effort and Rest take Today's values, so they are opened from the rings instead.
            let routes: [String: ForgeRoute] = ["charge": .charge, "weekly": .weeklyReport, "forgestrength": .strength, "muscles": .muscles, "forgeworkouts": .workouts, "weekplan": .weekPlan, "search": .search, "forgeageless": .ageless, "forgecycle": .cycle]
            // The cycle demo turns cycle tracking on; the seeder adds the cycle with `--demo-cycle`.
            if args.contains("--demo-cycle"), !UserDefaults.standard.bool(forKey: AppModel.cycleAwarenessKey) {
                UserDefaults.standard.set(true, forKey: AppModel.cycleAwarenessKey)
            }
            switch args[i + 1].lowercased() {
            case "settings": _showAllFeatures = State(initialValue: true)
            case "settings-strap", "settings-devices", "settings-scores":
                let sub: [String: ForgeSettingsRoute] = ["settings-strap": .strap, "settings-devices": .devicesSources, "settings-scores": .scoringGuide]
                var paths = Array(repeating: NavigationPath(), count: 5)
                if let route = sub[args[i + 1].lowercased()] { paths[4].append(route) }
                _tabPaths = State(initialValue: paths)
                _showAllFeatures = State(initialValue: true)
            case "log": _quickAction = State(initialValue: .forgeLog)
            case let key:
                // Shared screens pushed from the redesign's tabs, by the tab they hang off.
                let shared: [String: (Int, (inout NavigationPath) -> Void)] = [
                    "workouts": (2, { $0.append(TabRoute.workouts) }), "strength": (2, { $0.append(TabRoute.strength) }), "cardio": (2, { $0.append(TabRoute.cardio) }),
                    "trainingload": (2, { $0.append(TabRoute.trainingLoad) }), "goals": (2, { $0.append(TabRoute.goals) }), "plan": (2, { $0.append(MoreDestination.training) }),
                    "intervals": (2, { $0.append(MoreDestination.intervals) }), "live": (2, { $0.append(MoreDestination.live) }),
                    "insights": (1, { $0.append(MoreDestination.insightsHub) }), "intelligence": (1, { $0.append(MoreDestination.intelligence) }), "momentum": (1, { $0.append(MoreDestination.momentum) }),
                    "rhythm": (1, { $0.append(MoreDestination.rhythm) }), "applehealth": (0, { $0.append(MoreDestination.appleHealth) }), "miband": (0, { $0.append(MoreDestination.miBand) }),
                    "limits": (0, { $0.append(MoreDestination.noopLimitations) }), "testcentre": (0, { $0.append(MoreDestination.testCentre) }), "siri": (0, { $0.append(MoreDestination.siriShortcuts) }),
                    "powersaving": (0, { $0.append(MoreDestination.powerSaving) }), "journey": (2, { $0.append(MoreDestination.goalJourney) }), "energyplan": (1, { $0.append(MoreDestination.energyPlan) }),
                    "fused": (1, { $0.append(MoreDestination.fusedRecord) }), "shortcutsexport": (0, { $0.append(MoreDestination.shortcutsExport) }),
                    "hydration": (1, { $0.append(TabRoute.hydration) }), "weight": (1, { $0.append(TabRoute.weight) }), "energy": (1, { $0.append(TabRoute.energy) }), "stress": (1, { $0.append(TabRoute.stress) }),
                    "ecg": (1, { $0.append(MoreDestination.ecg) }), "body": (1, { $0.append(MoreDestination.body) }), "ageless": (1, { $0.append(MoreDestination.ageless) }),
                    "labbook": (1, { $0.append(MoreDestination.labBook) }), "breathe": (1, { $0.append(MoreDestination.breathe) }), "explore": (1, { $0.append(MoreDestination.explore) }),
                    "compare": (1, { $0.append(MoreDestination.compare) }), "trends": (1, { $0.append(TabRoute.trends) }), "metric-hrv": (1, { $0.append(TabRoute.metric("hrv")) }),
                    "focus-fitness": (1, { $0.append(ForgeRoute.focus(.fitness)) }), "focus-sleep": (1, { $0.append(ForgeRoute.focus(.sleep)) }),
                    "focus-vitals": (1, { $0.append(ForgeRoute.focus(.vitals)) }), "focus-body": (1, { $0.append(ForgeRoute.focus(.body)) }),
                    "focus-mind": (1, { $0.append(ForgeRoute.focus(.mind)) }), "focus-more": (1, { $0.append(ForgeRoute.focus(.more)) }), "fullday": (1, { $0.append(TabRoute.fullDayChart) }),
                    "alarms": (3, { $0.append(MoreDestination.alarms) }), "devices": (0, { $0.append(MoreDestination.devices) }), "backup": (0, { $0.append(MoreDestination.backupSync) }),
                    "datasources": (0, { $0.append(MoreDestination.dataSources) }), "automations": (0, { $0.append(MoreDestination.automations) })]
                var paths = Array(repeating: NavigationPath(), count: 5)
                if let route = routes[key] {
                    paths[0].append(route)
                    _tabPaths = State(initialValue: paths)
                } else if let (tab, push) = shared[key] {
                    push(&paths[tab])
                    _tabPaths = State(initialValue: paths)
                    _selectedTab = State(initialValue: tab)
                }
            }
        }
        #endif
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
    /// Only a decisive horizontal flick switches tabs. Today uses horizontal swipe to change DAYS, so
    /// the attachment mask below disables this recognizer there entirely. Both thresholds are unchanged
    /// from the original gesture.
    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                // Defensive guard for a selection change during an in-flight gesture. The GestureMask at
                // the attachment site keeps this recognizer out of Today hit testing in the steady state.
                guard selectedTab != 0 else { return }
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.6 else { return }
                let order = tabOrder
                guard let index = order.firstIndex(of: selectedTab) else { return }
                let next = order[min(order.count - 1, max(0, index + (dx < 0 ? 1 : -1)))]
                if next != selectedTab {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = next }
                }
            }
    }

    /// The tab tags in the order the bar shows them. The redesign keeps the tags (so every stack and
    /// route keeps its index) and only changes what tag 1 shows (Health instead of Trends) and its place.
    private var tabOrder: [Int] { forgeDesign ? [0, 2, 3, 1] : [0, 1, 2, 3, 4] }

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
            Group {
                if forgeDesign {
                    forgeTabView
                } else {
                    TabView(selection: nativeTabSelection) {
                        tab(todayTabRoot, "Today", "square.grid.2x2", path: $tabPaths[0], scrollSignal: scrollTop[0]).environment(\.dashboardIsActive, selectedTab == 0).tag(0)
                        tab(TrendsView(), "Trends", "chart.line.uptrend.xyaxis", path: $tabPaths[1], scrollSignal: scrollTop[1]).environment(\.dashboardIsActive, selectedTab == 1).tag(1)
                        tab(TrainingHubView(), "Training", "dumbbell.fill", path: $tabPaths[2], scrollSignal: scrollTop[2]).environment(\.dashboardIsActive, selectedTab == 2).tag(2)
                        tab(SleepView(), "Sleep", "bed.double", path: $tabPaths[3], scrollSignal: scrollTop[3]).environment(\.dashboardIsActive, selectedTab == 3).tag(3)
                        moreTab(path: $tabPaths[4], scrollSignal: scrollTop[4]).environment(\.dashboardIsActive, selectedTab == 4).tag(4)
                    }
                }
            }
            // Overview Dashboard mockup fidelity (2026-08-31): the active tab reads green, not the
            // configurable Accent colour. `.tint()` colours the whole bar uniformly — there is no native
            // per-tab-item override — so this is deliberately a global change across all four tabs.
            // The redesign tints with its own accent (copper in light, gold in dark).
            .tint(forgeDesign ? ForgeColor.accent : StrandPalette.chargeColor)
            // Shared cards rest on their fill alone under the redesign, as its own cards do.
            .environment(\.noopQuietCardRims, forgeDesign)
            // #1841: the same "Hide bar when scrolling" preference the macOS settings screen exposes.
            // Here the system owns the behaviour — iOS 26's tab bar MINIMISES to a pill on scroll down
            // rather than sliding away entirely, so this is the platform's read of the same intent.
            .noopTabBarAutoHide(bottomBarAutoHide)
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
            .simultaneousGesture(
                tabSwipeGesture,
                including: selectedTab != 0 && tabPaths[selectedTab].isEmpty ? .all : .subviews
            )
            // The minimized running workout, above the tab bar on every tab.
            .activeSessionMiniBar()

            // Draggable floating Coach button — an alternative entry to the Today banner, honouring the
            // user's Coach-entry preference. Floats over every tab; a tap opens the chat.
            if coachFeatureEnabled, coachUIEnabled, coachFloatingButtonEnabled, !forgeTabBarHostsCoach {
                CoachFloatingButton(isPresented: $showCoach)
            }
        }
        .coachCover(isPresented: $showCoach, coach: coach)
        .confirmationDialog("Let the coach use your data for this?",
                            isPresented: Binding(get: { pendingAsk != nil }, set: { if !$0 { pendingAsk = nil } }),
                            titleVisibility: .visible) {
            Button("Allow and ask") { sendPendingAsk(withData: true) }
            Button("Ask without my data") { sendPendingAsk(withData: false) }
            Button("Cancel", role: .cancel) { pendingAsk = nil }
        } message: {
            Text("Data sharing is off, so the coach only sees your question. Allowing it sends a short summary of your relevant metrics to your provider when you ask. You can turn it off again in Coach settings.")
        }
        .activeSessionPresentation()
        .task { await session.restoreIfNeeded() }
        // A quick-action sheet (Live, Start workout) may still be up when a session asks to present.
        // iOS cannot stack the session's cover or dialog on top of it, so close the sheet first and
        // re-issue the request once it has gone.
        .onReceive(session.$isPresented.removeDuplicates()) { presented in
            guard presented, quickAction != nil else { return }
            session.isPresented = false
            quickAction = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { session.present() }
        }
        .onReceive(session.$isChoosingStrengthStart.removeDuplicates()) { choosing in
            guard choosing, quickAction != nil else { return }
            session.isChoosingStrengthStart = false
            quickAction = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { session.isChoosingStrengthStart = true }
        }
        .onReceive(session.$pendingStart.map { $0 != nil }.removeDuplicates()) { pending in
            guard pending, quickAction != nil, let request = session.pendingStart else { return }
            session.pendingStart = nil
            quickAction = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { session.pendingStart = request }
        }
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
        .sheet(item: $quickAction, onDismiss: {
            guard customizeTodayAfterDismissal else { return }
            customizeTodayAfterDismissal = false
            tabPaths[0] = NavigationPath()
            selectedTab = 0
            router.presentTodayCustomization = true
        }) { action in
            quickActionDestination(action)
        }
        // Live's "Manage devices" affordance (and any future cross-screen link to Devices) routes here:
        // present the Devices manager in its own nav stack, the same way the quick-action screens do.
        .sheet(isPresented: $showDevices) {
            devicesScreen
        }
        // The redesign's "All features": the More index with its own stack, opened from the profile button.
        .sheet(isPresented: $showAllFeatures) {
            NavigationStack(path: $tabPaths[4]) {
                ForgeSettingsView { MoreDeviceRow(model: model) }
                    .navigationDestination(for: MoreDestination.self) { route in
                        route.destination
                            .background(StrandPalette.surfaceBase.ignoresSafeArea())
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .navigationDestination(for: ForgeSettingsRoute.self) { route in
                        switch route {
                        case .allFeatures:
                            moreIndexContent
                                .noopCardKind(.navigation)
                                .navigationBarTitleDisplayMode(.inline)
                        case .scoringGuide:
                            ForgeHowScoresView(onClose: {
                                if !tabPaths[4].isEmpty { tabPaths[4].removeLast() }
                            })
                        case .strap:
                            ForgeStrapSettingsView { MoreDeviceRow(model: model) }
                        case .devicesSources:
                            ForgeDevicesSourcesView()
                        }
                    }
                    // The Settings search and its results open the redesign's pages and the shared screens.
                    .forgeRouteDestinations(coach: coach, onAsk: askCoach)
                    .tabRouteDestinations()
            }
            .onChangeCompat(of: tabPaths[4].count) { _ in moreSearchFocused = false }
            .presentationDragIndicator(.visible)
        }
        // Activity detection: a notification tap or "Other kind…" opens the logging sheet from any tab.
        .activitySuggestionSheetHost(repo)
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
            case .insightsHub, .labBook, .fusedRecord, .rhythm, .alarms:
                routedPillar = dest
                router.requestedDestination = nil
            case .coach:
                // The fork keeps Coach under More rather than giving it a dedicated tab. Route every
                // launcher and notification through that one canonical destination, and drop stale
                // notification requests when the master switch is off instead of opening hidden UI.
                guard coachFeatureEnabled else {
                    router.requestedDestination = nil
                    break
                }
                openCoachArea()
                router.requestedDestination = nil
            case .trends:
                // Trends is a primary tab on iPhone (not a pillar sheet) — switch to it. The redesign keeps
                // it under Health, so it is pushed there.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
                if forgeDesign { tabPaths[1] = NavigationPath([TabRoute.trends]) }
                router.requestedDestination = nil
            case .sleep:
                // Sleep is a primary tab too. Raised by the morning card's "Fix it" when last night's
                // wake time looks truncated, so the editor is one tap away rather than a hunt.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 3 }
                router.requestedDestination = nil
            case .goals:
                // Goal widget, lock-screen accessory, notification or Siri: the overview (and the goal)
                // pushed on Today's stack, the same routes Today's own goals section uses.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                var path = NavigationPath([TabRoute.goals])
                if let id = router.requestedGoalId { path.append(TabRoute.periodGoal(id)) }
                tabPaths[0] = path
                router.requestedGoalId = nil
                router.requestedDestination = nil
            case .todayDetail:
                // A fitness widget's deep link: land on Today and push the detail its Today card opens.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                tabPaths[0] = NavigationPath(router.requestedTodayRoute.map { [$0] } ?? [])
                router.requestedTodayRoute = nil
                router.requestedDestination = nil
            case .lab:
                // A feature introduction in the bell: Settings → Lab on the More tab's own stack, appended
                // like Data Sources so Back returns the reader to where they were.
                openMoreArea()
                tabPaths[4].append(MoreDestination.settingsPage(.lab))
                router.requestedDestination = nil
            case .energy:
                // Widget deep link: land on Today and push the same detail route the in-app card uses.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                tabPaths[0] = NavigationPath([TabRoute.energy])
                router.requestedDestination = nil
            case .activeWorkout:
                // Whatever was started and wherever, the running session opens through its controller.
                router.presentActiveWorkout = false
                session.present()
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
                openMoreArea()
                // Appended rather than assigned (the Coach deep links REPLACE the More stack): if the
                // reader was already somewhere under More, Back should return them there instead of
                // dropping them at the index. From any other tab the stack is at its root, so this
                // behaves exactly like a replace.
                tabPaths[4].append(MoreDestination.dataSources)
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        // Daily coach check-in tapped (NOOP Forge): jump to the More tab and open Coach on top of it.
        // CoachView refreshes the brief itself — it observes the same event.
        .onReceive(NotificationCenter.default.publisher(for: .noopOpenCoachCheckIn)) { _ in
            guard coachFeatureEnabled else { return }
            openCoachArea()
        }
        // "Ask coach" tapped on a metric card (#P11): same jump — open Coach on top of the More tab; it
        // reads the pending card context and gives a short read of that metric.
        .onReceive(NotificationCenter.default.publisher(for: .noopOpenCoachCard)) { _ in
            guard coachFeatureEnabled else { return }
            openCoachArea()
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
            ForgeDesignPrefs.mirrorToAppGroup()
        }
        .onChange(of: forgePreviewStored) { _, _ in
            ForgeDesignPrefs.mirrorToAppGroup()
            NoopVisualStyle.skin = forgeDesign ? .forge : .standard
            ForgeDesignPrefs.applyListChrome()
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

        if action == .goals {
            // A push on the Today stack, like the battery row, not a sheet.
            homeScreenQuickActions.consume(action)
            showDevices = false
            routedPillar = nil
            quickAction = nil
            selectedTab = 0
            tabPaths[0] = NavigationPath()
            tabPaths[0].append(TabRoute.goals)
            return
        }
        let destination: QuickAction = switch action {
        case .liveHeartRate: .live
        case .startWorkout: .workout
        case .logJournal: .journal
        case .goals: .goals
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
                // #1862: Coach IS presented here — the launcher sheet routes to it as a pillar, so unlike
                // the fallbacks above this arm is the real destination, not a safety net.
                case .coach: CoachView()
                case .alarms: SmartAlarmView()
                // .goals is pushed onto Today's own stack (handled above); exhaustive fallback.
                case .goals: CoachGoalJourneyScreen()
                // .todayDetail is pushed onto Today's own stack (handled above); exhaustive fallback.
                case .todayDetail: LiquidTodayView()
                // .lab is pushed onto the More tab's own stack (handled above); exhaustive fallback.
                case .lab: SettingsView(initialPage: .lab)
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
                if picked == .customizeToday {
                    customizeTodayAfterDismissal = true
                    quickAction = nil
                    return
                }
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    // The guardian is a full-screen cover, not one of the sheet destinations — route it to
                    // its own presentation flag rather than back through `quickAction`.
                    if picked == .liveSession { showLiveSession = true }
                    else if picked == .battery {
                        // A Today-stack screen, not a sheet destination: push it where the old header
                        // battery button used to.
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                        tabPaths[0].append(TabRoute.battery)
                    }
                    else if picked == .goals {
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                        tabPaths[0].append(TabRoute.goals)
                    }
                    else if picked == .workout, model.activeWorkout != nil {
                        quickAction = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { session.present() }
                    }
                    else { withAnimation(Self.sheetEase) { quickAction = picked } }
                }
            }
            .presentationDetents([.height(600), .large])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            // Straight to the shared start screen (strength and every other activity): "Start workout"
            // should start one, not open the history list. A running session is re-presented instead (the picker would only offer to stack a second).
            // The session cover cannot sit on this sheet; the `session.$isPresented` hook below closes the
            // sheet and re-issues the present.
            StartWorkoutSheet(session: session)
        case .journal:
            quickScreen(InsightsView())
        case .breathe:
            quickScreen(BreathingView())
        case .forgeLog:
            ForgeLogSheet(onPick: { choice in handleForgeLog(choice) }, acceptsPhotos: coach.acceptsPhotos)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .liveSession, .battery, .customizeToday, .goals:
            // Never reached: the picker routes the guardian to `showLiveSession` (a full-screen cover) and
            // the device row to the Today stack, so this arm only keeps the switch exhaustive.
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

    // MARK: - Redesign (New design preview)

    /// From iOS 18 the redesign's tab bar carries the coach as its own round button (iOS 26 draws a
    /// `.search`-role tab apart from the others), so the floating button is not shown twice.
    private var forgeTabBarHostsCoach: Bool {
        guard forgeDesign else { return false }
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// Tag of the coach button in the redesign's bar. Never becomes the selection: choosing it opens the chat.
    private static let forgeCoachTag = 9

    private var forgeSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { tag in
                if tag == Self.forgeCoachTag {
                    if coachFeatureEnabled { showCoach = true }
                } else if tag == selectedTab {
                    reselectTab(tag)
                } else {
                    selectedTab = tag
                }
            }
        )
    }

    private var forgeTodayRoot: some View {
        ForgeTodayView(
            coach: coach,
            onProfile: { showAllFeatures = true },
            onLog: { withAnimation(Self.sheetEase) { quickAction = .forgeLog } },
            onWorkout: {
                if model.activeWorkout != nil { session.present() }
                else { withAnimation(Self.sheetEase) { quickAction = .workout } }
            },
            onCoach: { if coachFeatureEnabled { showCoach = true } },
            onSleep: { withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 3 } },
            onCoachSettings: { pushOnToday(MoreDestination.coachSettings) },
            onAsk: askCoach
        )
        .safeAreaInset(edge: .bottom, spacing: 0) { AnalysisUpdateBanner() }
    }

    private var forgeTrainingRoot: some View {
        ForgeTrainingView(onProfile: { showAllFeatures = true }, onStartWorkout: {
            if model.activeWorkout != nil { session.present() }
            else { withAnimation(Self.sheetEase) { quickAction = .workout } }
        }, onAsk: askCoach)
    }

    private var forgeSleepRoot: some View {
        ForgeSleepView(onProfile: { showAllFeatures = true }, onAsk: askCoach)
    }

    private var forgeHealthRoot: some View {
        ForgeHealthView(onProfile: { showAllFeatures = true }, onAsk: askCoach)
    }

    @ViewBuilder private var forgeTabView: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: forgeSelection) {
                Tab("Today", systemImage: "sun.max.fill", value: 0) {
                    tabStack(forgeTodayRoot, path: $tabPaths[0], scrollSignal: scrollTop[0], registersMore: true)
                        .environment(\.forgeTab, .today)
                        .environment(\.dashboardIsActive, selectedTab == 0)
                }
                Tab("Training", systemImage: "figure.run", value: 2) {
                    tabStack(forgeTrainingRoot, path: $tabPaths[2], scrollSignal: scrollTop[2], registersMore: true)
                        .environment(\.forgeTab, .training)
                        .environment(\.dashboardIsActive, selectedTab == 2)
                }
                Tab("Sleep", systemImage: "moon.fill", value: 3) {
                    tabStack(forgeSleepRoot, path: $tabPaths[3], scrollSignal: scrollTop[3], registersMore: true)
                        .environment(\.forgeTab, .sleep)
                        .environment(\.dashboardIsActive, selectedTab == 3)
                }
                Tab("Health", systemImage: "heart.fill", value: 1) {
                    tabStack(forgeHealthRoot, path: $tabPaths[1], scrollSignal: scrollTop[1], registersMore: true)
                        .environment(\.forgeTab, .health)
                        .environment(\.dashboardIsActive, selectedTab == 1)
                }
                if coachFeatureEnabled {
                    Tab("Coach", systemImage: "bubble.left.and.text.bubble.right.fill", value: Self.forgeCoachTag,
                        role: .search) {
                        Color.clear
                    }
                }
            }
        } else {
            TabView(selection: nativeTabSelection) {
                tab(forgeTodayRoot, "Today", "sun.max.fill", path: $tabPaths[0], scrollSignal: scrollTop[0], registersMore: true).environment(\.dashboardIsActive, selectedTab == 0).tag(0)
                tab(forgeTrainingRoot, "Training", "figure.run", path: $tabPaths[2], scrollSignal: scrollTop[2], registersMore: true).environment(\.dashboardIsActive, selectedTab == 2).tag(2)
                tab(forgeSleepRoot, "Sleep", "moon.fill", path: $tabPaths[3], scrollSignal: scrollTop[3], registersMore: true).environment(\.dashboardIsActive, selectedTab == 3).tag(3)
                tab(forgeHealthRoot, "Health", "heart.fill", path: $tabPaths[1], scrollSignal: scrollTop[1], registersMore: true).environment(\.dashboardIsActive, selectedTab == 1).tag(1)
            }
        }
    }

    /// Where a route that used to land on the More tab goes: the More tab itself, or in the redesign the
    /// "All features" sheet, which hosts the same stack (`tabPaths[4]`).
    private func openMoreArea() {
        if forgeDesign {
            showAllFeatures = true
        } else {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 4 }
        }
    }

    /// Every coach launcher and notification. The shipped shell opens Coach on the More stack; the redesign
    /// presents the chat cover from wherever the person is.
    private func openCoachArea() {
        if forgeDesign {
            let wasShowingSheet = showAllFeatures || quickAction != nil
            showAllFeatures = false
            quickAction = nil
            if wasShowingSheet {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showCoach = true }
            } else {
                showCoach = true
            }
        } else {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 4 }
            tabPaths[4] = NavigationPath([MoreDestination.coach])
        }
    }

    /// The Log sheet's choices, each mapped to a screen that already exists.
    private func handleForgeLog(_ choice: ForgeLogChoice) {
        quickAction = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            switch choice {
            case .coachWrite, .coachSpeak:
                if coachFeatureEnabled { showCoach = true }
            case .coachPhoto(let png):
                guard coachFeatureEnabled else { return }
                showCoach = true
                Task {
                    await coach.sendPhoto(png, question: String(localized: "Here is a photo I want to log, such as a meal or a workout screen. Say what you see and what I could log from it. Mark any estimate as an estimate and do not log anything yourself."))
                }
            case .workout:
                if model.activeWorkout != nil { session.present() }
                else { withAnimation(Self.sheetEase) { quickAction = .workout } }
            case .journal: withAnimation(Self.sheetEase) { quickAction = .journal }
            case .breathe: withAnimation(Self.sheetEase) { quickAction = .breathe }
            case .liveHeartRate: withAnimation(Self.sheetEase) { quickAction = .live }
            case .weight: pushOnToday(TabRoute.weight)
            case .drink: pushOnToday(TabRoute.hydration)
            case .energy: pushOnToday(TabRoute.energy)
            case .sleep: withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 3 }
            case .labMarkers: routedPillar = .labBook
            }
        }
    }

    private func pushOnToday<R: Hashable>(_ route: R) {
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
        tabPaths[0].append(route)
    }

    /// "Ask the coach" from any redesigned tab: hand the question to the chat and open it. With data
    /// sharing off the question would get a generic answer, so the person is asked right there whether the
    /// coach may use their data (inline consent) instead of being sent to Settings.
    private func askCoach(_ question: String) {
        guard coachFeatureEnabled else { return }
        if coach.isConfigured, !coach.dataConsent {
            pendingAsk = question
            return
        }
        coach.pendingPrompt = question
        showCoach = true
    }

    private func sendPendingAsk(withData: Bool) {
        guard let question = pendingAsk else { return }
        pendingAsk = nil
        if withData { coach.dataConsent = true }
        coach.pendingPrompt = question
        showCoach = true
    }

    /// One tab's navigation stack without its bar item, shared by both tab APIs.
    /// The redesign's tabs also push More's destinations (ECG, Body, AgeLess, ...), since there is no More
    /// tab to reach them from; registered once per stack, like `tabRouteDestinations`.
    private func tabStack<V: View>(_ view: V, path: Binding<NavigationPath>, scrollSignal: Int,
                                   registersMore: Bool = false) -> some View {
        NavigationStack(path: path) {
            Group {
                if registersMore {
                    view.navigationDestination(for: MoreDestination.self) { $0.destination }
                        .forgeRouteDestinations(coach: coach, onAsk: askCoach)
                } else {
                    view
                }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .tabRouteDestinations()
        }
        .environment(\.scrollToTopSignal, scrollSignal)
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String,
                              path: Binding<NavigationPath>, scrollSignal: Int,
                              registersMore: Bool = false) -> some View {
        // Each primary tab gets its OWN NavigationStack so the in-content NavigationLinks (e.g. the Today
        // dashboard card rows) both navigate AND render opaque. An ORPHANED NavigationLink (no
        // NavigationStack ancestor) renders its whole label in a disabled/translucent state — that was
        // washing the Today cards over the hero scene and dimming their text to grey (2026-06-23).
        // The root view hides the system nav bar (each screen draws its own in-content header); pushed
        // detail screens get their own nav bar + back button. The stack is bound to the tab's path so a
        // re-tap of the active tab can pop it to the root (#135/#198); the roots' first-hop links push
        // TabRoute values, registered here ONCE per stack (a double registration double-pushes, #38).
        // Drive this tab's root scroll-to-top on an at-root re-tap (#198 follow-up); read by ScreenScaffold
        // / LiquidTodayView inside. Only THIS tab's token changes on its reselect, so the others don't scroll.
        tabStack(view, path: path, scrollSignal: scrollSignal, registersMore: registersMore)
            .tabItem { Label(title, systemImage: icon) }
    }

    // Analysis migration required: no. This is navigation and presentation only; stored health inputs,
    // derived values and their invalidation semantics are unchanged.
    /// The More index itself (profile, device, search, groups, quick access). The shipped shell shows it as
    /// the More tab; the redesign pushes it as "All features" from its Settings sheet.
    @ViewBuilder private var moreIndexContent: some View {
        ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                       onRefresh: { await repo.refresh() },
                       topBackground: liquidScaffoldSky()) {
            MoreProfileRow()
            MoreDeviceRow(model: model)

            NoopLiquidGlassSearchField(
                text: $moreQuery,
                prompt: String(localized: "Search screens and settings"),
                accessibilityLabel: String(localized: "Search screens and settings"),
                isFocused: $moreSearchFocused
            )

            if isSearchingMore {
                moreSearchResults
            } else {
                NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                    MoreRow(MoreCatalog.goalsEntry)
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Browse").strandOverline()
                    VStack(spacing: 12) {
                        ForEach(MoreCatalog.groups) { group in
                            MoreCategoryRow(category: group.category)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick access").strandOverline()
                    NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                        VStack(spacing: 0) {
                            ForEach(MoreCatalog.rootEntries) { entry in MoreRow(entry) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius,
                                                    style: .continuous))
                    }
                }
            }
        }
    }

    private func moreTab(path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        NavigationStack(path: path) {
            moreIndexContent
            .noopCardKind(.navigation)
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
        .onChangeCompat(of: path.wrappedValue.count) { _ in moreSearchFocused = false }
        // Scroll the More index to the top on an at-root re-tap (#198 follow-up); read by its ScreenScaffold.
        .environment(\.scrollToTopSignal, scrollSignal)
        .tabItem { Label("More", systemImage: "ellipsis") }
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
                let settingPages = SettingsPage.allCases.filter { page in
                    settings.contains(where: { $0.page == page })
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Settings").strandOverline()
                    NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                        VStack(spacing: 0) {
                            ForEach(settingPages) { page in
                                let matches = settings.filter { $0.page == page }
                                    .map { String(localized: $0.title) }
                                    .joined(separator: " · ")
                                // Straight to the page that holds the match. Each page appears once even
                                // if several of its controls match.
                                MoreRow(matches, page.icon, .settingsPage(page),
                                        caption: String(localized: page.title), colorKey: page.colorKey)
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
    case category(MoreCategory)
    case profile, devices, training
    case momentum
    case insightsHub, intelligence, coach, coachSettings, goalJourney, insights, explore, compare
    case live, workouts, health, labBook, stress, breathe, intervals, rhythm, ecg, strength, cardio, trainingLoad
    case body, energyPlan
    case ageless, rhythmAge
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport, noopLimitations
    case alarms, automations, testCentre, siriShortcuts, powerSaving, settings
    /// Settings opened from a search hit, carrying the query so the screen lands already filtered to
    /// the matching section. Distinct from `.settings` (the plain row) so an ordinary tap on the
    /// Settings row still opens the whole screen.
    case settingsSearch(String)
    /// One Settings page, opened from a More search hit.
    case settingsPage(SettingsPage)

    @ViewBuilder var destination: some View {
        switch self {
        case .category(let category): MoreCategoryView(category: category)
        case .profile:         SettingsView(initialPage: .profile)
        case .devices:         DevicesView()
        case .training:        TrainingHubView()
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
        case .strength:        StrengthView()
        case .cardio:          CardioView()
        case .trainingLoad:    TrainingLoadView()
        case .body:            BodyView()
        case .energyPlan:      EnergyPlanView()
        case .health:          HealthView()
        case .ageless:         AgeLessScreen()
        case .rhythmAge:       RhythmAgeDetailView()
        case .labBook:         LabBookView()
        case .stress:          StressView()
        case .breathe:         BreathingView()
        case .intervals:       IntervalTimerView()
        case .rhythm:          RhythmHost()
        case .ecg:             EcgReadingsScreen()
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
        case .settingsPage(let page): SettingsPageDestination(page: page)
        }
    }
}


/// One tappable destination row in the More index. A `NavigationLink` whose label is the standard app row:
/// the SF Symbol in its semantic Apple-inspired colour tile, the title in the body text colour, a `Spacer`, and a
/// trailing `chevron.right` in `textTertiary`. ~44pt min height + the card's row insets keep the whole row a
/// comfortable tap target.
struct MoreRow: View {
    let title: String
    let icon: String
    let route: MoreDestination
    /// Secondary line under the title. Only the search results use it — to say WHERE a hit lives
    /// ("in Settings"), which a flat result list otherwise leaves the reader to guess.
    var caption: String?
    /// Key for the semantic icon colour. Defaults to the route's own name, which is what every
    /// grouped row uses; a search result whose route carries an associated value (`.settingsSearch`)
    /// passes the plain key so it keeps the Settings colour instead of falling off the lookup.
    var colorKey: String?

    init(_ entry: MoreEntry) {
        self.init(String(localized: entry.title), entry.icon, entry.route)
    }

    init(_ title: String,
         _ icon: String,
         _ route: MoreDestination,
         caption: String? = nil,
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
                    .fill(StrandPalette.hairline.opacity(0.32))
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
        }
    }
// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe, liveSession
    /// The device row at the top of the menu: opens the battery screen on the Today stack.
    case battery, customizeToday
    /// The goals overview, pushed on the Today stack like the battery screen.
    case goals
    /// The redesign's Log sheet.
    case forgeLog
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
    @EnvironmentObject private var live: LiveState

    /// One line for the device row, or nil when the active device has no charge of its own to report
    /// (the same rule that hid the old header control, #2208).
    private var deviceStatus: String? {
        #if DEBUG
        // `--demo-sync` stands in for a connected strap on Today; the row answers the same way.
        if DemoSyncHarness.active {
            return String(localized: "Connected · Battery \(Int(DemoSyncHarness.batteryPercent.rounded()))%")
        }
        #endif
        let display = StrapBatteryDisplayState.resolve(
            activeIsWhoop: live.activeIsWhoop, connected: live.connected,
            batteryPct: live.batteryPct, charging: live.charging,
            ringPct: live.ouraBatteryPct, ringCharging: live.ouraWearState == .charging)
        switch display {
        case .notActiveDevice: return nil
        case .offline: return String(localized: "Not connected")
        case .pending: return live.backfilling ? String(localized: "Syncing") : String(localized: "Connected")
        case .charge(let pct, let charging, _):
            if live.backfilling { return String(localized: "Syncing") }
            return charging ? String(localized: "Charging")
                : String(localized: "Connected · Battery \(Int(pct.rounded()))%")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle (36×4) in the slate hairline tone.
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 0) {
                    // The active wearable's charge and link, moved here from Today's header. Tapping it opens the
                    // battery screen, as the header control did.
                    if let status = deviceStatus {
                        row("Battery", icon: "battery.75percent", tint: StrandPalette.statusPositive,
                            subtitle: LocalizedStringKey(status)) { onPick(.battery) }
                            .padding(.horizontal, NoopMetrics.screenHPadding)
                            .padding(.bottom, 14)
                    }

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
                        row("Goals", icon: "target", tint: StrandPalette.chargeColor) { onPick(.goals) }
                        if liveSessionsBeta {
                            // A Live Session is NOT a breathing exercise — it is quiet strap coaching against
                            // today's Charge — so it carries a subtitle here. Sitting one row under "Breathe"
                            // without one, the two would read as duplicates of each other.
                            row("Silent Guardian", icon: "shield.lefthalf.filled", tint: StrandPalette.metricCyan,
                                subtitle: "Quiet strap coaching against today's Charge") { onPick(.liveSession) }
                        }
                    }
                    .padding(.horizontal, NoopMetrics.screenHPadding)

                    Divider().padding(.vertical, NoopMetrics.space4)
                        .padding(.horizontal, NoopMetrics.screenHPadding)
                    row("Customize home", icon: "slider.horizontal.3", tint: StrandPalette.textSecondary) {
                        onPick(.customizeToday)
                    }
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.bottom, NoopMetrics.space4)
                }
            }
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

/// Profile and device status stay visible at the top of More, matching the hierarchy people already
/// know from Apple Health and the major fitness apps. Both rows are deliberately compact: the details
/// live on their destination pages.
private struct MoreProfileRow: View {
    @EnvironmentObject private var profile: ProfileStore

    var body: some View {
        NavigationLink(value: MoreDestination.profile) {
            StrandCard(padding: 16, cornerRadius: NoopMetrics.groupedRadius) {
                HStack(spacing: 14) {
                    ProfileAvatarView(imageData: profile.avatarImageData, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? String(localized: "Set up your profile") : profile.name)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Personal details, body metrics and heart-rate zones")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MoreDeviceRow: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Strap history is syncing, through the same debounce as Today's sync line (`debouncedSyncSignal`), so the
    /// row does not flicker between offload chunks.
    @State private var syncing = false

    private var activeDevice: PairedDevice? {
        model.deviceRegistry?.devices.first { $0.status == .active && !$0.isImportSource }
    }

    private var status: String {
        guard activeDevice != nil else { return String(localized: "Connect a wearable or sensor") }
        guard live.connected else { return String(localized: "Not connected") }
        if syncing { return String(localized: "Syncing…") }
        if let battery = live.batteryPct {
            return String(localized: "Connected · Battery \(Int(battery.rounded()))%")
        }
        return String(localized: "Connected")
    }

    var body: some View {
        NavigationLink(value: MoreDestination.devices) {
            NoopCard(padding: 16, cornerRadius: NoopMetrics.groupedRadius) {
                HStack(spacing: 14) {
                    Image(systemName: live.connected ? "sensor.tag.radiowaves.forward.fill" : "sensor.tag.radiowaves.forward")
                        .appleInspiredMenuIcon("deviceSetup", size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeDevice?.displayName ?? String(localized: "Devices"))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(live.connected ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(status)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .debouncedSyncSignal(live.backfilling, into: $syncing)
    }
}

private struct MoreCategoryRow: View {
    let category: MoreCategory

    var body: some View {
        NavigationLink(value: MoreDestination.category(category)) {
            NoopCard(padding: 16, cornerRadius: NoopMetrics.groupedRadius) {
                HStack(spacing: 14) {
                    Image(systemName: category.icon)
                        .appleInspiredMenuIcon(category.colorKey, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(category.subtitle)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct MoreCategoryView: View {
    let category: MoreCategory
    // Observed so a Lab switch flipped elsewhere adds or removes its row here.
    @AppStorage(HealthspanFeature.defaultsKey) private var healthspanEnabled = false
    @AppStorage(RhythmAgeFeature.defaultsKey) private var rhythmAgeEnabled = false

    var body: some View {
        ScreenScaffold(
            title: LocalizedStringKey(String(localized: category.title)),
            subtitle: LocalizedStringKey(String(localized: category.subtitle)),
            topBackground: liquidScaffoldSky()
        ) {
            NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                VStack(spacing: 0) {
                    ForEach(MoreCatalog.group(for: category).entries.filter(\.isAvailable)) { entry in MoreRow(entry) }
                }
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
            }
        }
        .noopCardKind(.navigation)
    }
}


#endif

/// #1841: apply the iOS 26 tab-bar minimise behaviour, doing nothing on older systems.
///
/// The availability branch is deliberately the ONLY branch. `RootTabView` already documents what happens
/// when a condition that flips at runtime wraps this `TabView`: #519 put two states in separate
/// `_ConditionalContent` branches, and every navigation rebuilt the whole subtree, resetting `@State`
/// inside the tab roots — scroll offsets, chart ranges, expanded sections.
///
/// So the preference must NOT select between branches. It selects the modifier's ARGUMENT, while the
/// availability check — fixed for the life of the process — is what picks a branch. Toggling the setting
/// changes a value, never the view's identity.
extension View {
    @ViewBuilder
    func noopTabBarAutoHide(_ enabled: Bool) -> some View {
        if #available(iOS 26.0, *) {
            // `.onScrollDown` minimises to a pill on downward scroll; `.never` pins it fully visible.
            self.tabBarMinimizeBehavior(enabled ? .onScrollDown : .never)
        } else {
            self
        }
    }
}
