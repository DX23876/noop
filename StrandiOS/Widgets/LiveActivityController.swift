#if os(iOS)
import Foundation
import ActivityKit
import Combine
import UIKit

/// Starts, updates, and ends the live-HR Live Activity on the Lock Screen and in the Dynamic Island: the heart rate
/// while the strap measures it, the dash while it does not. It follows the strap from process start (`follow`).
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    /// What the banner reads — the live heart rate, the link, the day's recovery and effort — set once by `follow`.
    private weak var model: AppModel?
    /// Whether the Lift Log banner is on screen, which the heart rate banner makes room for.
    private var standsAside: () -> Bool = { false }
    private var cancellables: Set<AnyCancellable> = []
    private var lastPush: Date = .distantPast
    /// What the banner was last pushed with, so an unchanged banner is not pushed again
    /// (`LiveHRBannerPushPolicy`). Nil until this controller pushes, and again once it ends the activity.
    private var shownState: NOOPActivityAttributes.ContentState?
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// When the banner being fed was started, for iOS's eight-hour limit (`LiveHRBannerLifecycle.renewAfter`). Kept in
    /// the defaults with the banner's id, because a banner outlives the run that started it. Nil when unknown.
    private var startedAt: Date?
    private static let startedKey = "liveActivity.hr.startedAt"
    /// An end is in flight, so the ticks that arrive meanwhile neither end it again nor log it twice.
    private var isEnding = false
    /// iOS refused a start, and it was logged: once, not on every tick while NOOP is on screen.
    private var refusalLogged = false
    /// Banners NOOP has asked iOS to remove (`removeLeftovers`), so a tick that arrives before iOS has dropped one from
    /// its list neither asks again nor logs it twice.
    private var removing: Set<String> = []
    /// How long after the last push iOS treats the banner as fresh; after that the banner draws the dash
    /// (`NOOPLiveActivity.shownBpm`). A WHOOP 5.0 taken off the wrist goes quiet, and with nothing arriving iOS
    /// suspends NOOP, so no timer of NOOP's can clear the number: iOS's own stale date is what does it, in at most
    /// this long (a tester's log, 23 Sep 2026). A steady number is re-pushed once half of this has passed
    /// (`LiveHRBannerPushPolicy`), so a banner fed by a worn strap never goes stale.
    static let staleAfter: TimeInterval = 30

    /// Follow the strap from process start, not from a screen. iOS starts NOOP in the background — the strap
    /// reconnecting, a sync, the Sync Strap shortcut — and a process started that way need not build any screen (the
    /// shortcut's never does), while a banner the previous run left on the Lock Screen is there to be picked up and
    /// fed from the first reading. Called once, from the app's `init`, like the Lift Log's own resume.
    func follow(_ model: AppModel, standsAside: @escaping () -> Bool) {
        self.model = model
        self.standsAside = standsAside
        // Refreshed once a change has landed, never from inside it (`LiveHRBannerInputs`). AppModel's median (`bpm`)
        // is an input in its own right: it moves on the R-R alone, and a clear that reached it that way refreshed
        // nothing, so the banner kept the last number until iOS's stale date drew the dash.
        LiveHRBannerInputs.settled([model.live.$heartRate.map { _ in () }.eraseToAnyPublisher(),
                                    model.live.$connected.map { _ in () }.eraseToAnyPublisher(),
                                    model.$bpm.map { _ in () }.eraseToAnyPublisher()])
            .sink { [weak self] in self?.refreshBanner() }
            .store(in: &cancellables)
        // The switch is the one way to be rid of the banner, so it acts at once — not at the next heart-rate tick,
        // which a strap off the wrist may not send for hours.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in UnitPrefs.liveActivityEnabled() }
            .prepend(UnitPrefs.liveActivityEnabled())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refreshBanner() }
            .store(in: &cancellables)
        // The workout switch acts at once too: turning it off mid-session ends the banner, turning it on shows it.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in UnitPrefs.workoutLiveActivityEnabled() }
            .prepend(UnitPrefs.workoutLiveActivityEnabled())
            .removeDuplicates()
            .dropFirst()
            .sink { [weak model] _ in model?.session.publishActivity() }
            .store(in: &cancellables)
    }

    /// NOOP came on screen, the only time iOS lets it start the banner: offered now rather than at the next heart-rate
    /// change, which a strap off the wrist may not bring for a long while. Said by the caller, from the scene phase,
    /// because `applicationState` can still read inactive while the scene turns active.
    func appBecameActive() {
        refreshBanner(appActive: true)
    }

    /// #911: recovery and effort come from the SAME shared `Repository.widgetAnchor` the widget and the watch use, so
    /// the banner cannot name a different day at the rollover; memoized, because this runs on every heart-rate tick
    /// (re-deriving it once scanned the whole history, #1051).
    private func refreshBanner(appActive: Bool? = nil) {
        guard let model else { return }
        let connected = model.live.connected
        let day = model.repo.cachedWidgetAnchor()
        update(bpm: connected ? (model.bpm ?? model.live.heartRate) : nil,
               recovery: day?.recovery.map { Int($0.rounded()) }, connected: connected, standsAside: standsAside(),
               appActive: appActive ?? (UIApplication.shared.applicationState == .active),
               effort: day?.strain.map { Int($0.rounded()) })
    }

    /// Drive the activity from the latest live values (`LiveHRBannerLifecycle` decides start / push / end). Starts
    /// only in the foreground (`appActive`), with the strap CONNECTED (the live link, not the sticky "paired" flag),
    /// before a heart rate arrives if need be; a running banner shows the dash through a dropped link or a strap
    /// that is not measuring, and ends only when its switch is off or the Lift Log banner takes the screen
    /// (`standsAside`). Pushed when what it shows changes, and often enough to stay fresh (`LiveHRBannerPushPolicy`,
    /// `staleAfter`).
    private func update(bpm: Int?, recovery: Int?, connected: Bool, standsAside: Bool, appActive: Bool,
                        effort: Int?) {
        guard authInfo.areActivitiesEnabled else { return }
        // A running workout owns the activity; the plain live-HR summary resumes after it ends.
        guard currentWorkout == nil, model?.session.hasLiveSession != true else { return }

        // A banner iOS ended (after about eight hours) or the user swiped away is gone: forget it, so the next time
        // NOOP is on screen it starts one again rather than pushing to nothing. (One NOOP is ending is not gone yet.)
        if !isEnding, let activity, !Self.isShowing(activity) {
            self.activity = nil
            shownState = nil
            startedAt = nil
            log((Self.listed(activity) == .ended ? "ended by iOS" : "gone from the Lock Screen (dismissed)")
                + "; started again when NOOP is next on screen")
        }
        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch. A banner iOS ended is
        // removed here too, whichever run fed it: it can only show its last number.
        if activity == nil {
            let listed = Activity<NOOPActivityAttributes>.activities
            removeLeftovers(listed, beside: nil)
            if let adopted = listed.first(where: {
                $0.attributes.title != Self.workoutTitle && Self.isShowing($0)
            }) {
                activity = adopted
                startedAt = (UserDefaults.standard.dictionary(forKey: Self.startedKey)?[adopted.id] as? Double)
                    .map(Date.init(timeIntervalSince1970:))
                log("picked up the one already on the Lock Screen")
            }
        }

        // The switch (#336) and the gym banner on screen end it; nothing that passes does (`LiveHRBannerLifecycle`).
        let now = Date()
        let switchOn = UnitPrefs.liveActivityEnabled()
        let age = startedAt.map { now.timeIntervalSince($0) }
        let step = LiveHRBannerLifecycle.step(
            switchOn: switchOn, standsAside: standsAside, linkUp: connected,
            showing: activity != nil, age: age, appActive: appActive)
        switch step {
        case .nothing: return
        case .end:
            guard !isEnding else { return }
            isEnding = true
            log(switchOn ? "ended: the Lift Log banner takes its place" : "ended: its switch is off")
            Task { await end() }
            return
        case .start, .push, .renew: break
        }

        // Link down: the dash, never the last number (`bonded` stays true across a disconnect, and keying off it once
        // left a fabricated "live" HR standing). No timed end: a timer in a suspended app fires at its next wake,
        // which is typically the strap coming back — exactly when the banner should stay.
        let state = NOOPActivityAttributes.ContentState(bpm: connected ? bpm : nil, recovery: recovery,
                                                        bonded: connected, effort: effort)

        if step == .renew, activity != nil {
            // The fresh banner first, then the old one goes, so the Lock Screen is never without one; if iOS refuses
            // the fresh one, the old one stays.
            if start(state, at: now) {
                log("renewed after \(age.map { "\(Int($0 / 60)) min" } ?? "an unknown time"), "
                    + "so iOS's eight-hour limit starts again")
                removeLeftovers(Activity<NOOPActivityAttributes>.activities, beside: activity)
            }
        } else if let activity {
            // The number giving way to the dash (the strap off the wrist, the link dropping) is pushed at once: no
            // tick follows it, so a push skipped for spacing would leave the last number standing.
            guard LiveHRBannerPushPolicy.due(shown: shownState, next: state, reading: \.bpm,
                                             sinceLastPush: now.timeIntervalSince(lastPush),
                                             staleAfter: Self.staleAfter) else { return }
            if let shown = shownState, (shown.bpm == nil) != (state.bpm == nil) { logReading(state) }
            lastPush = now
            shownState = state
            let staleDate = now.addingTimeInterval(Self.staleAfter)
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else if start(state, at: now) {
            log(state.bpm == nil ? "started, showing – until a heart rate arrives" : "started")
            removeLeftovers(Activity<NOOPActivityAttributes>.activities, beside: activity)
        }
    }

    /// Removes at once each banner in `listed` that `LiveHRBannerLifecycle.removes` says goes: one iOS has ended, which
    /// stays on the Lock Screen frozen on its last number and takes no update, and — once NOOP has started `fresh` —
    /// any other one still showing. Each removal of an ended one leaves a line: it is what a second banner beside the
    /// live one would have been.
    private func removeLeftovers(_ listed: [Activity<NOOPActivityAttributes>],
                                 beside fresh: Activity<NOOPActivityAttributes>?) {
        for act in listed where act.id != fresh?.id {
            let state = Self.listed(act)
            guard LiveHRBannerLifecycle.removes(state, besideFresh: fresh != nil),
                  removing.insert(act.id).inserted else { continue }
            if state == .ended { log("removed one iOS had ended, which could only show its last number") }
            Task { await act.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Ask iOS for a new banner, which it grants only while NOOP is on screen. Returns whether it did.
    @discardableResult
    private func start(_ state: NOOPActivityAttributes.ContentState, at now: Date) -> Bool {
        // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
        // main actor while `Activity.request` is still in flight bails here instead of issuing a
        // second request. The 2-second throttle above only guards the update path.
        guard !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        do {
            let started = try Activity.request(
                attributes: NOOPActivityAttributes(title: String(localized: "Live HR")),
                content: ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
            activity = started
            startedAt = now
            UserDefaults.standard.set([started.id: now.timeIntervalSince1970], forKey: Self.startedKey)
            lastPush = now
            shownState = state
            refusalLogged = false
            return true
        } catch {
            if !refusalLogged {
                refusalLogged = true
                log("iOS did not start it: \(error.localizedDescription)")
            }
            return false
        }
    }

    // MARK: - Workout

    /// The workout the activity currently shows, or nil when it shows live HR (or nothing).
    private var currentWorkout: NOOPActivityAttributes.Workout?
    /// Owns the replace-and-request sequence. Ending a workout or disabling its switch cancels this task
    /// and advances the generation, preventing an old request from recreating a finished banner.
    private var workoutStartTask: Task<Void, Never>?
    private var workoutGeneration = 0
    /// A workout start iOS refused because NOOP was not yet active, retried once it is. A restored, paused
    /// workout with no strap publishes nothing else, so without this its banner never appeared.
    private var deferredWorkoutStart: NSObjectProtocol?

    /// Shows the running workout, or ends the workout activity when `snapshot` is nil. A workout activity
    /// lives as long as the session, not as long as the strap connection. Structural changes (pause, a rest
    /// starting or ending, a set completed) are pushed at once; heart rate and distance at most every 2 s.
    func updateWorkout(_ snapshot: LiveWorkoutActivitySnapshot?, now: Date = Date()) {
        guard let snapshot else {
            workoutSkipLogged = nil
            invalidateWorkoutStart()
            guard currentWorkout != nil || activity?.attributes.title == Self.workoutTitle
                    || Self.hasListedWorkoutActivity else { return }
            currentWorkout = nil
            logWorkout("ended: the workout is over")
            Task { await end() }
            return
        }
        guard authInfo.areActivitiesEnabled else {
            invalidateWorkoutStart()
            logWorkoutSkip("not shown: Live Activities are off for NOOP in iOS Settings")
            if currentWorkout != nil || Self.hasListedWorkoutActivity {
                currentWorkout = nil
                Task { await end() }
            }
            return
        }
        guard UnitPrefs.workoutLiveActivityEnabled() else {
            invalidateWorkoutStart()
            logWorkoutSkip("not shown: its switch in Settings > Live notifications is off")
            if currentWorkout != nil || Self.hasListedWorkoutActivity {
                currentWorkout = nil
                logWorkout("ended: its switch is off")
                Task { await end() }
            }
            return
        }
        let workout = Self.workoutState(snapshot, now: now)
        let state = NOOPActivityAttributes.ContentState(bpm: snapshot.bpm, recovery: nil, bonded: true,
                                                        effort: nil, workout: workout)
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter))

        // Re-adopt the workout banner ActivityKit kept across a process restart. Selecting by title is
        // essential because the same attributes type also backs the plain live-HR banner.
        if activity == nil || activity?.attributes.title != Self.workoutTitle {
            let listed = Activity<NOOPActivityAttributes>.activities
            if let adopted = listed.first(where: {
                $0.attributes.title == Self.workoutTitle && Self.isShowing($0)
            }) {
                activity = adopted
                currentWorkout = workout
                lastPush = now
                workoutSkipLogged = nil
                Task { await adopted.update(content) }
                removeLeftovers(listed, beside: adopted)
                logWorkout("picked up the workout already on the Lock Screen")
                return
            }
        }
        if let activity, activity.attributes.title == Self.workoutTitle,
           currentWorkout == nil, Self.isShowing(activity) {
            currentWorkout = workout
            lastPush = now
            workoutSkipLogged = nil
            Task { await activity.update(content) }
            logWorkout("picked up the workout already on the Lock Screen")
            return
        }

        let showsWorkout = currentWorkout != nil && activity?.attributes.title == Self.workoutTitle
        if let activity, showsWorkout {
            let structural = Self.isStructuralChange(from: currentWorkout, to: workout)
            guard structural || now.timeIntervalSince(lastPush) > 2 else { return }
            currentWorkout = workout
            lastPush = now
            Task { await activity.update(content) }
            return
        }
        // ActivityKit only accepts a new activity from the foreground app. Leave `currentWorkout` unset so the
        // next publish after returning to the app starts it.
        guard UIApplication.shared.applicationState == .active else {
            logWorkoutSkip("waiting: iOS starts it only while NOOP is on screen")
            retryWorkoutStartWhenActive(snapshot)
            return
        }
        guard !isStarting else { return }
        isStarting = true
        currentWorkout = workout
        workoutGeneration += 1
        let generation = workoutGeneration
        workoutStartTask?.cancel()
        workoutStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A live-HR activity was requested with a different title; replace it with the workout one.
            await self.end()
            guard !Task.isCancelled, self.workoutGeneration == generation,
                  self.currentWorkout != nil, UnitPrefs.workoutLiveActivityEnabled() else {
                self.isStarting = false
                return
            }
            do {
                self.activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: Self.workoutTitle),
                    content: content, pushType: nil)
                self.lastPush = Date()
                self.workoutSkipLogged = nil
                self.logWorkout("started (\(workout.kind.rawValue))")
            } catch {
                self.activity = nil
                // Unset, so the next publish (the next set, the next return to the app) asks again.
                self.currentWorkout = nil
                self.logWorkoutSkip("iOS did not start it: \(error.localizedDescription)")
            }
            self.isStarting = false
            if self.workoutGeneration == generation { self.workoutStartTask = nil }
        }
    }

    private func invalidateWorkoutStart() {
        workoutGeneration += 1
        workoutStartTask?.cancel()
        workoutStartTask = nil
        isStarting = false
    }

    /// The last reason a workout banner was not shown, logged once rather than on every publish. Cleared when one
    /// starts or the workout ends, so the next session's first refusal is logged again.
    private var workoutSkipLogged: String?

    /// The workout banner's own lines in the strap log. It used to write none — a refusal from iOS was swallowed
    /// and the switch skipped silently — so a log could not say why a Lock Screen stayed empty during a session.
    private func logWorkout(_ line: String) {
        model?.live.append(log: AppModel.stamped("Workout banner: " + line))
    }

    private func retryWorkoutStartWhenActive(_ snapshot: LiveWorkoutActivitySnapshot) {
        if let deferredWorkoutStart { NotificationCenter.default.removeObserver(deferredWorkoutStart) }
        deferredWorkoutStart = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.deferredWorkoutStart { NotificationCenter.default.removeObserver(observer) }
                self.deferredWorkoutStart = nil
                self.updateWorkout(snapshot)
            }
        }
    }

    private func logWorkoutSkip(_ reason: String) {
        guard workoutSkipLogged != reason else { return }
        workoutSkipLogged = reason
        logWorkout(reason)
    }

    /// Distinguishes a workout activity from the live-HR one without a second attributes type.
    static let workoutTitle = "workout"

    /// ActivityKit can outlive this controller. Consult its process-wide roster before deciding there
    /// is no workout banner to end, especially directly after a relaunch or settings change.
    private static var hasListedWorkoutActivity: Bool {
        Activity<NOOPActivityAttributes>.activities.contains {
            $0.attributes.title == workoutTitle && listed($0) != .gone
        }
    }

    static func workoutState(_ snapshot: LiveWorkoutActivitySnapshot, now: Date) -> NOOPActivityAttributes.Workout {
        .init(kind: snapshot.kind == .strength ? .strength : .cardio, title: snapshot.title,
              elapsedAnchor: snapshot.elapsedAnchor,
              pausedElapsedSeconds: snapshot.pausedAt == nil ? nil : snapshot.activeSeconds(at: now),
              zone: snapshot.zone, distanceM: snapshot.distanceM, paceSecPerKm: snapshot.paceSecPerKm,
              setsDone: snapshot.setsDone, setsTotal: snapshot.setsTotal, restEndsAt: snapshot.restEndsAt,
              notice: snapshot.notice, symbol: snapshot.symbol)
    }

    /// Changes the Lock Screen must reflect immediately rather than on the next throttled push.
    static func isStructuralChange(from old: NOOPActivityAttributes.Workout?,
                                   to new: NOOPActivityAttributes.Workout) -> Bool {
        guard let old else { return true }
        return (old.pausedElapsedSeconds == nil) != (new.pausedElapsedSeconds == nil)
            || old.restEndsAt != new.restEndsAt
            || old.notice != new.notice
            || old.setsDone != new.setsDone
            || old.setsTotal != new.setsTotal
            || old.title != new.title
            || old.elapsedAnchor != new.elapsedAnchor
    }

    /// The banner turning to the dash, or back to a number: pushed at once (`LiveHRBannerPushPolicy`), and logged.
    private func logReading(_ state: NOOPActivityAttributes.ContentState) {
        if state.bpm != nil {
            log("heart rate again")
        } else {
            log(state.bonded ? "– (strap connected, no heart rate)" : "– (strap not connected)")
        }
    }

    /// One line in NOOP's strap log for each thing that happens to the banner: started, picked up, renewed, ended,
    /// gone, and each turn to the dash and back. Rare, so always on. A tester's banner once showed the dash for a
    /// strap he was wearing, and a log without a word about the banner could not say why (24 Sep 2026).
    private func log(_ line: String) {
        model?.live.append(log: AppModel.stamped("Live HR banner: " + line))
    }

    /// Still on the Lock Screen and able to take an update: not ended by iOS, the user or NOOP.
    private static func isShowing(_ activity: Activity<NOOPActivityAttributes>) -> Bool {
        listed(activity) == .showing
    }

    /// The banner's state in `LiveHRBannerLifecycle`'s terms. `pending` (a start iOS 26 schedules) never comes from
    /// NOOP, which only starts banners at once, so it counts as gone: not NOOP's to feed or remove.
    private static func listed(_ activity: Activity<NOOPActivityAttributes>) -> LiveHRBannerLifecycle.Listed {
        switch activity.activityState {
        case .active, .stale: return .showing
        case .ended: return .ended
        default: return .gone
        }
    }

    func end() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        shownState = nil
        startedAt = nil
        isEnding = false
        if currentWorkout == nil { lastPush = .distantPast }
    }
}
#endif
