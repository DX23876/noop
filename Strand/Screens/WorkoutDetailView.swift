import SwiftUI
import StrandDesign
import StrandAnalytics
import StrandImport
import WhoopStore
import Foundation
import StrandCore
#if canImport(MapKit)
import MapKit
#endif

// MARK: - Workout detail (#410)
//
// A READ-ONLY drill-down for one tapped session, built ONLY from the locked Noop component system
// (NoopCard / ChartCard / SectionHeader / StatTile / SegmentBar idiom) so it sits in the same
// instrument-grade, Effort-amber colour world as the Workouts list it opens from.
//
//   • a header (sport displayName · date · duration) with the source badge,
//   • a 3-up StatTile strip (avg HR · max HR · calories / distance),
//   • a GPS route map when the session recorded one on-device (#524) — a MapKit map of the captured
//     polyline with start/end markers, shown only when points were actually captured,
//   • an HR-curve ChartCard fed the workout's 5-min-ish HR buckets over [startTs, endTs],
//   • an HR-zones bar — imported per-workout zones when the row carries them, else the window's raw
//     HR samples binned into age-derived %HRmax zone-minutes (honestly labelled as approximate),
//   • the session's Effort/strain contribution when one was captured.
//
// Presented as a `.sheet` wrapped in a NavigationStack by WorkoutsView — these screens aren't hosted in
// a per-screen NavigationStack, so a sheet is the in-app drill-down idiom (mirrors HealthView opening
// MetricDetailView, StressView opening Breathe).

struct WorkoutDetailView: View {
    let row: WorkoutRow

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Loaded HR curve over the session window (5-min-ish bucket means). Empty until loaded.
    @State private var hrPoints: [TrendPoint] = []
    /// The session's own readings, for an average and peak the source did not store (an Apple walk).
    @State private var rawHeartBpm: [Double] = []
    /// Per-zone MINUTES for the zones bar: imported zones (duration-weighted) when present, else the
    /// window's raw HR samples binned into age-derived %HRmax zones. nil = no zone split to show.
    @State private var zoneMinutes: [Double]? = nil
    /// True when the zones bar came from imported WHOOP percentages (vs derived from raw strap HR).
    @State private var zonesFromImport = false
    @State private var loaded = false
    /// #516: computed from the recorded workout-end + post-workout HR window. nil when the workout was
    /// not intense enough or the strap did not record enough post-workout coverage.
    @State private var heartRateRecovery: HeartRateRecovery.Result?

    /// The GPS route captured for this session on-device (#524), if any. Decoded from `RouteStore` by the
    /// row's natural key. nil = no route was recorded (honest — the map only shows when points exist).
    @State private var route: [RouteMath.LatLng] = []
    @State private var routeSegments: [[RouteMath.LatLng]]? = nil
    @State private var recordings: [CompletedWorkoutRecording] = []
    /// The route's heights (recorded barometer or Apple Health altitude) and the workout's resolved climb.
    @State private var elevationSeries: WorkoutElevationSeries?
    @State private var elevation: WorkoutElevationRow?

    /// Drives the GPX/FIT export chooser for the recorded route.
    @State private var showRouteExport = false

    /// Steps over the session window for an on-foot sport (#398): the count plus whether it came from the
    /// strap's own counter (MG/5.0) or the phone pedometer (fallback for WHOOP 4.0 / not-yet-synced / CSV
    /// import). nil = not an on-foot sport, or no step source had data for the window.
    private struct StepReadout {
        enum Origin { case strap, health, phone }
        let count: Int
        let origin: Origin
    }
    @State private var steps: StepReadout?
    /// Where an Apple Health row's heart rate came from when NOOP filled it (`workoutHeartRateFill`):
    /// shown in place of the unit under the average, so a filled value is never mistaken for Health's own.
    @State private var heartRateOrigin: String?
    /// This session's energy and where it came from. Resolved at display time and never written
    /// back: an estimate that got stored would read as a measurement the next time anything asked.
    @State private var energy: WorkoutEnergyEstimate.Resolved?
    /// Still being worked out, so the tile shows progress instead of the "–" that means "no data".
    @State private var stepsPending = true
    @State private var energyPending = true

    /// False when the detail is pushed onto a stack (the new design's Workouts page) rather than shown in a
    /// sheet, so there is no Done button to close a sheet that is not there.
    var showsDone = true

    var body: some View {
        if NoopVisualStyle.skin == .forge {
            forgeBody
        } else {
            classicBody
        }
    }

    private var classicBody: some View {
        ScreenScaffold(title: "\(WorkoutSource.displaySport(row.sport))",
                       subtitle: "\(dateLabel(row.startTs))",
                       // PERF: chart/map-heavy column (a MapKit route map, the session HR curve, the
                       // zone-split chart and the effort card). The LazyVStack path builds the off-screen
                       // ones on demand — byte-identical layout — so a tall detail doesn't materialise the
                       // map + both charts before the header is even on screen.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching the Workouts list this detail opens from
                       // and every other liquid screen. Fixed and full-bleed; it does not scroll. This
                       // screen is presented in a sheet wrapped in a NavigationStack by WorkoutsView, so it
                       // needs no extra macOS NavigationStack of its own.
                       topBackground: liquidScaffoldSky()) {
            headerCard
            GoalContributionNote(row: row)
            statStrip
            routeCard
            WorkoutElevationCard(series: elevationSeries, elevation: elevation, sport: row.sport,
                                 system: distanceUnitSystem)
            ForEach(recordings) { recording in
                WorkoutRecordingSectionsView(timeline: recording.timeline,
                                             seconds: recording.row.durationS ?? 0,
                                             sport: recording.row.sport,
                                             elevation: elevationSeries)
            }
            hrCurveCard
            workoutExportCard
            zonesCard
            heartRateRecoveryCard
            if let strain = row.strain {
                effortCard(strain: strain)
            }
            SessionRPECard(startTs: row.startTs, sport: row.sport,
                           durationS: row.durationS ?? Double(row.endTs - row.startTs))
        }
        .toolbar {
            // A Done affordance for the sheet on both platforms (iOS gets the grabber too).
            if showsDone {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Load

    private func load() async {
        // Cheap things first, published as soon as they are known: everything below reads the raw
        // streams, and waiting for all of it held the route, the steps and a recorded calorie figure
        // back by a second or two behind a blank tile.
        //
        // #524: the GPS route, if this session recorded one on-device. A cheap UserDefaults read keyed
        // by the row's natural key (startTs + sport); decoded to points only when ≥2 were captured so the
        // map only ever draws a real route.
        let recordings = (try? await repo.workoutRecordings(for: row)) ?? []
        let segments = recordings.flatMap { $0.route?.segments ?? [] }
        let routePoints: [RouteMath.LatLng] = {
            if !segments.isEmpty { return segments.flatMap { $0 } }
            guard let r = RouteStore.load(startTs: row.startTs, sport: row.sport) else { return [] }
            let pts = RouteMath.decode(r.polyline)
            return pts.count >= 2 ? pts : []
        }()
        let analytics = Repository.analyticsProfile(profile)
        let recorded = (row.energyKcal ?? 0) > 0
        let fill = await repo.workoutHeartRateFill(for: row)
        let elevation = await repo.workoutElevation(for: row)
        let measured = recordings.flatMap { $0.route?.points ?? [] }
        let heightPoints = measured.isEmpty
            ? (RouteStore.loadWithPoints(startTs: row.startTs, sport: row.sport)?.points ?? [])
            : measured
        let series = WorkoutElevationSeries.make(points: heightPoints)
        await MainActor.run {
            self.elevation = elevation
            self.elevationSeries = series
            self.route = routePoints
            self.routeSegments = segments.isEmpty ? nil : segments
            self.recordings = recordings
            self.heartRateOrigin = fill.map {
                $0.hrSource == WorkoutHeartRateFill.Source.band.rawValue
                    ? String(localized: "strap") : String(localized: "Apple Watch")
            }
            // A recorded figure needs none of the inputs an estimate reads (`resolve` returns it first).
            if recorded {
                self.energy = WorkoutEnergyDisplay.resolve(row, profile: analytics,
                                                           hrMax: Double(profile.hrMax), restingHrByDay: [:])
                self.energyPending = false
            }
        }

        // Steps and the energy estimate read different streams, so they load side by side rather
        // than the estimate queueing behind the step count.
        async let stepsDone: Void = loadSteps()
        async let energyDone: Void = recorded ? () : loadEstimatedEnergy(profile: analytics)
        _ = await (stepsDone, energyDone)

        // HR curve over the exact session window — a finer bucket than the 24h chart so a short run
        // still reads as a curve, not a handful of points.
        let buckets = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs, source: row.source)
        let points = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
        // The chart's buckets are means, so a peak read from them falls short of the real one. A source
        // without its own average or peak gets both from the readings themselves.
        let rawBpm: [Double] = (row.avgHr == nil || row.maxHr == nil)
            ? await repo.workoutHrSamples(from: row.startTs, to: row.endTs, source: row.source).map { Double($0.bpm) }
            : []

        // Zones: prefer the imported per-workout percentages (a WHOOP-computed split), and only fall
        // back to deriving zone-minutes from the strap's own raw HR when the row has none — so we
        // never overwrite a real imported split with an on-device approximation.
        var minutes: [Double]?
        var fromImport = false
        let capturedZones = recordings.map {
            $0.timeline.zoneSeconds(at: $0.row.durationS ?? 0)
        }.filter { $0.count == 5 }
        if !capturedZones.isEmpty {
            minutes = (0..<5).map { zone in capturedZones.reduce(0) { $0 + $1[zone] } / 60 }
        } else if let pct = WorkoutZones.percents(row.zonesJSON) {
            let durMin = (row.durationS ?? Double(row.endTs - row.startTs)) / 60.0
            if durMin > 0 {
                minutes = pct.map { durMin * $0 / 100.0 }
                fromImport = true
            }
        }
        if minutes == nil {
            minutes = await repo.workoutZoneMinutes(from: row.startTs, to: row.endTs,
                                                    zoneSet: profile.hrZoneSet, source: row.source)
        }

        let hrr = await repo.workoutHeartRateRecovery(
            from: row.startTs, to: row.endTs, maxHR: Double(profile.hrMax), source: row.source)

        await MainActor.run {
            self.hrPoints = points
            self.rawHeartBpm = rawBpm
            self.zoneMinutes = minutes
            self.zonesFromImport = fromImport
            self.heartRateRecovery = hrr
            self.loaded = true
        }
    }

    /// Steps for an on-foot session (#398), computed at display time over the exact window so it
    /// "fills in after sync": prefer the strap's own counter (MG/5.0) once it has offloaded the window,
    /// else the phone pedometer (any strap, incl. WHOOP 4.0 / CSV-import). Never shown for non-foot
    /// sports (cycling/rowing/… have no footfalls). Both sources return nil for "no data", so an empty
    /// window stays "–" rather than a fabricated 0.
    private func loadSteps() async {
        var stepReadout: StepReadout? = nil
        if WorkoutCatalog.isOnFoot(row.sport) {
            if let ticks = await repo.strapStepTicks(from: row.startTs, to: row.endTs) {
                // Same per-user ticks-per-step calibration the daily total applies (#139), floor 0.5.
                let scaled = Int((Double(ticks) / max(profile.stepTicksPerStep, 0.5)).rounded())
                if scaled > 0 { stepReadout = StepReadout(count: scaled, origin: .strap) }
            }
            // An Apple Health workout's own count (Watch and phone, merged by Health) before the phone's
            // pedometer alone.
            if stepReadout == nil, WorkoutSource.isAppleHealth(row.source), let health = row.steps, health > 0 {
                stepReadout = StepReadout(count: health, origin: .health)
            }
            if stepReadout == nil,
               let ped = await WorkoutPedometer.steps(fromSec: row.startTs, toSec: row.endTs), ped > 0 {
                stepReadout = StepReadout(count: ped, origin: .phone)
            }
        }
        await MainActor.run {
            self.steps = stepReadout
            self.stepsPending = false
        }
    }

    private func loadEstimatedEnergy(profile analytics: UserProfile) async {
        // The day's resting rate, not a default: it sets the activity gate the estimate is measured
        // against, and the wrong one moves this session's figure by hundreds of kcal.
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
        let restingByDay = await repo.restingHrByDay(fromDay: day, toDay: day)
        // The strap model's own figure for this window, when it covered it — the figure the day's
        // energy already counts. The list reads the same thing, so the two cannot disagree.
        let strapByKey = await repo.strapSessionEnergy(for: [row])
        let peakByDay = await repo.energyPeakMETByDay(fromDay: day, toDay: day)
        let resolvedEnergy = WorkoutEnergyDisplay.resolve(
            row, profile: analytics, hrMax: Double(profile.hrMax),
            restingHrByDay: restingByDay, strapKcalByKey: strapByKey, peakMETByDay: peakByDay)
        await MainActor.run {
            self.energy = resolvedEnergy
            self.energyPending = false
        }
    }

    /// "kcal" for a recorded figure; what it was estimated from otherwise. A caption that appears on
    /// every session is a caption nobody reads, so the recorded case keeps the plain unit.
    private var energyCaption: String? {
        guard energy != nil else { return nil }
        return WorkoutEnergyDisplay.caption(energy) ?? String(localized: "kcal")
    }

    // MARK: - Heart-rate recovery (#516)

    @ViewBuilder private var heartRateRecoveryCard: some View {
        if let recovery = heartRateRecovery {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate Recovery", overline: "After high-intensity effort",
                              trailing: String(localized: "Peak \(recovery.endHR) bpm"))
                NoopCard(tint: StrandPalette.metricRose) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 0) {
                            recoveryStat(String(localized: "1 min"), value: recovery.after1Minute)
                            recoveryStat(String(localized: "2 min"), value: recovery.after2Minutes)
                            recoveryStat(String(localized: "5 min"), value: recovery.after5Minutes)
                        }
                        Divider().overlay(StrandPalette.hairline)
                        Text("The change from your heart rate at the end of exercise. Positive values mean your heart rate fell; a dash means the strap did not record enough data around that minute.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func recoveryStat(_ label: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).strandOverline()
            Text(value.map { "\($0)" } ?? "–")
                .font(StrandFont.number(24))
                .foregroundStyle(value.map { $0 >= 0 ? StrandPalette.statusPositive
                                                     : StrandPalette.statusWarningForeground }
                                 ?? StrandPalette.textTertiary)
            Text("bpm")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { String(localized: "Heart rate recovery at \(label), \($0) beats per minute") }
                            ?? String(localized: "Heart rate recovery at \(label), not available"))
    }

    // MARK: - Header

    private var headerCard: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: sportSymbol(row.sport))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(width: 44, height: 44)
                    .background(StrandPalette.effortColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WorkoutSource.displaySport(row.sport))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text("\(dateLabel(row.startTs)) · \(timeRangeLabel(row.startTs, row.endTs))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
                sourceBadge(row.source)
            }
        }
    }

    // MARK: - Stat strip

    @ViewBuilder private var statStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)],
                  alignment: .leading, spacing: NoopMetrics.gap) {
            StatTile(label: "Duration",
                     value: durationLabel(row.durationS),
                     caption: String(localized: "active"),
                     accent: StrandPalette.effortColor)
            StatTile(label: "Avg HR",
                     value: row.avgHr.map { "\($0)" } ?? "–",
                     caption: row.avgHr != nil ? (heartRateOrigin ?? "bpm") : nil,
                     accent: row.avgHr != nil ? StrandPalette.metricRose : StrandPalette.textTertiary)
            StatTile(label: "Max HR",
                     value: row.maxHr.map { "\($0)" } ?? "–",
                     caption: row.maxHr != nil ? "bpm" : nil,
                     accent: row.maxHr != nil ? StrandPalette.metricRose : StrandPalette.textTertiary)
            // An empty tile beside a full heart-rate curve was the complaint: a native, Hevy or
            // hand-entered session never records kcal, and the screen said nothing rather than
            // saying what it could work out. The tilde and the caption keep it an estimate.
            StatTile(label: "Calories",
                     value: WorkoutEnergyDisplay.text(energy, marksEstimate: NoopVisualStyle.skin != .forge) ?? (energyPending ? "…" : "–"),
                     caption: energyCaption,
                     accent: energy != nil ? StrandPalette.metricAmber : StrandPalette.textTertiary) {
                if energyPending && energy == nil { pendingIndicator }
            }
            if row.distanceM != nil {
                StatTile(label: "Distance",
                         value: distanceLabel(row.distanceM),
                         caption: String(localized: "covered"),
                         accent: StrandPalette.metricCyan)
            }
            // Steps for an on-foot sport (#398). Shown for the on-foot set even before the value lands, so
            // the tile doesn't pop in; "–" until a source has data. Caption is honest about the source.
            if WorkoutCatalog.isOnFoot(row.sport) {
                StatTile(label: "Steps",
                         value: steps.map { grouped(Double($0.count)) } ?? "–",
                         caption: steps.map {
                             switch $0.origin {
                             case .strap: return String(localized: "strap")
                             case .health: return String(localized: "Apple Health")
                             case .phone: return String(localized: "phone")
                             }
                         },
                         accent: steps != nil ? StrandPalette.metricCyan : StrandPalette.textTertiary) {
                    if stepsPending { pendingIndicator }
                }
            }
        }
    }

    /// Marks a tile whose value is still being worked out, as opposed to one with no data.
    private var pendingIndicator: some View {
        ProgressView().controlSize(.mini)
    }

    // MARK: - GPS route (#524)

    /// The captured-route card: a MapKit map of the polyline with start/end markers, plus distance and
    /// pace read off the route. Shown ONLY when ≥2 points were captured — honest "no map" otherwise (a
    /// Mac with no GPS, denied permission, or a non-distance sport never produce a route).
    @ViewBuilder private var routeCard: some View {
        if route.count >= 2 {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Route", overline: routeOriginLabel,
                              trailing: distanceLabel(row.distanceM))
                NoopCard(padding: 0, tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: 0) {
                        WorkoutRouteMap(points: route, segments: routeSegments)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius,
                                                        style: .continuous))
                            .accessibilityLabel(routeAccessibilityLabel)
                        HStack(spacing: 0) {
                            routeStat(String(localized: "Distance"), distanceLabel(row.distanceM),
                                      tint: StrandPalette.metricCyan)
                            routeStat(showsSpeed ? String(localized: "Avg speed") : String(localized: "Avg pace"),
                                      showsSpeed ? speedLabel : paceLabel, tint: StrandPalette.effortBright)
                            routeStat(String(localized: "Points"), "\(route.count)", tint: StrandPalette.textSecondary)
                        }
                        .padding(NoopMetrics.cardPadding)
                    }
                }
                Text(routeDescription)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showRouteExport = true
                } label: {
                    Label("Export route", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                .confirmationDialog("Export route", isPresented: $showRouteExport, titleVisibility: .visible) {
                    Button("GPX — Strava, Garmin, most apps") { exportWorkout(.gpx) }
                    Button("FIT — Garmin Connect") { exportWorkout(.fit) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Save this route as a standard file you can import into Strava, Garmin Connect, and other apps.")
                }
            }
        }
    }

    /// Write the workout to a GPX/FIT file and hand it to the system share sheet (or a Save panel on macOS).
    /// `WorkoutFileExport` resolves the file's contents from the row itself (track, measured times and
    /// heights, pauses, and in a FIT the heart-rate curve), the same builder the Shortcuts action uses.
    ///
    /// The build + disk write run OFF the main actor (a long route is a non-trivial encode, and blocking
    /// file IO must never stall the UI); only the share-sheet present hops back to the main actor.
    @MainActor private func exportWorkout(_ format: RouteExporter.Format) {
        let repo = repo, row = row
        Task.detached(priority: .userInitiated) {
            guard let file = await WorkoutFileExport.build(format, row: row, repo: repo) else { return }
            let url = NoopScratch.file(file.name)
            do { try file.data.write(to: url) } catch { return }
            await MainActor.run { FileExport.exportFile(at: url, suggestedName: file.name) }
        }
    }

    /// A workout without a route still exports as a FIT from its heart rate, so it can go to Strava or
    /// Garmin Connect by hand like a GPS one. Shown only when the strap curve has data to carry.
    @ViewBuilder private var workoutExportCard: some View {
        if route.count < 2 && !hrPoints.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Button {
                    exportWorkout(.fit)
                } label: {
                    Label("Export workout", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                Text("Save this workout with its heart rate as a FIT file you can import into Strava, Garmin Connect, and other apps.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func routeStat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).strandOverline()
            Text(value)
                .font(StrandFont.number(15))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Avg pace from the row's GPS distance + duration, in the user's unit system: "m:ss /km" (metric) or
    /// "m:ss /mi" (imperial). "–" when distance or duration is missing/zero (pace undefined — honest).
    private var paceLabel: String {
        guard let m = row.distanceM, m > 0 else { return "–" }
        let secs = row.durationS ?? Double(row.endTs - row.startTs)
        guard secs > 0 else { return "–" }
        let km = m / 1000.0
        return UnitFormatter.paceFromSecPerKm(secs / km, system: distanceUnitSystem)
    }

    /// A ride reads in speed, as every bike computer shows it: "2:31 /km" for a ride means nothing to a cyclist.
    private var showsSpeed: Bool {
        let sport = row.sport.lowercased()
        return ["cycl", "bik", "ride", "spin"].contains { sport.contains($0) }
    }

    private var speedLabel: String {
        guard let m = row.distanceM, m > 0 else { return "–" }
        let secs = row.durationS ?? Double(row.endTs - row.startTs)
        guard secs > 0 else { return "–" }
        return UnitFormatter.speedFromKilometersPerHour(m / 1000 / (secs / 3600), system: distanceUnitSystem) ?? "–"
    }

    private var routeAccessibilityLabel: String {
        let dist = distanceLabel(row.distanceM)
        return String(localized: "Map of your \(WorkoutSource.displaySport(row.sport)) route, \(dist).")
    }

    /// #1205: the route card's overline and description must be honest about where the route came
    /// from. An on-device recorded route says "Recorded on device"; an imported route (Apple Health
    /// or Health Connect) says "Imported from Apple Health" / "Imported" so the user is not told
    /// their phone recorded GPS data that actually came from another app.
    private var routeOriginLabel: LocalizedStringKey {
        switch WorkoutSource.classify(row.source) {
        // "Imported" rather than naming the app: every string here is one the catalog already carries in
        // all nine locales, so the honesty fix ships translated on day one. A source-specific variant
        // ("Imported from Apple Health") would be a NEW key, and nothing catches a missing entry: the i18n
        // audit checks locale coverage OF catalog entries, not that a `String(localized:)` literal has one.
        // It would have read English on every non-English device while the gate stayed green.
        case .apple, .whoop, .lifting, .activityFile, .hevy, .oura: return "Imported"
        case .detected, .manual, .confirmed: return "Recorded on device"
        }
    }

    private var routeDescription: String {
        switch WorkoutSource.classify(row.source) {
        // Same rule as the overline: both of these are existing catalog keys with all nine locales. The
        // imported line carries the privacy claim without the "recorded on your device" the original
        // string opens with, which is the part that was untrue for a route another app collected.
        case .apple, .whoop, .lifting, .activityFile, .hevy, .oura:
            return String(localized: "This stays on your device. It is never uploaded, never synced, never shared.")
        case .detected, .manual, .confirmed:
            return String(localized: "Your GPS route for this session, recorded and stored on your device. Nothing leaves your phone.")
        }
    }

    // MARK: - HR curve

    @ViewBuilder private var hrCurveCard: some View {
        if hrPoints.count > 1 {
            let values = hrPoints.map(\.value)
            let lo = max(0, (values.min() ?? 60) - 8)
            let hi = (values.max() ?? 180) + 8
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                ChartCard(
                    title: "HEART RATE",
                    subtitle: String(localized: "Beats per minute across the session"),
                    trailing: row.avgHr.map { String(localized: "avg \($0)") },
                    tint: StrandPalette.effortColor
                ) {
                    TrendChart(
                        points: hrPoints,
                        gradient: StrandPalette.effortGradient,
                        valueRange: lo...hi,
                        showsArea: true,
                        valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                        dateFormat: { Self.tooltipTime.string(from: $0) },
                        accessibilityLabel: String(localized: "Heart rate during \(WorkoutSource.displaySport(row.sport))"),
                        workoutTimeAxis: Date(timeIntervalSince1970: TimeInterval(row.startTs))...Date(timeIntervalSince1970: TimeInterval(row.endTs))
                    )
                } footer: {
                    ChartFooter([
                        ("Avg", row.avgHr.map { String(localized: "\($0) bpm") } ?? "–"),
                        ("Peak", row.maxHr.map { String(localized: "\($0) bpm") } ?? String(localized: "\(Int((values.max() ?? 0).rounded())) bpm")),
                        ("Low", String(localized: "\(Int((values.min() ?? 0).rounded())) bpm")),
                    ])
                }
                // #18: the row's Avg HR can be EDITED on the manual sheet while the graph, zones and Effort
                // stay from the recorded session (preservingCaptured keeps the captured strain/zones). When
                // the typed average disagrees materially with this trace's own mean AND the row carries that
                // captured strain/zones, say so plainly. We do NOT re-score from the typed number.
                if avgHrEditedDisclosure(traceMean: values.reduce(0, +) / Double(values.count)) {
                    Text("The average above was edited. The graph, zones and Effort stay from the recorded session.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if loaded {
            NoopCard {
                emptyNote("No heart-rate samples were recorded over this session's window.")
            }
        }
    }

    /// #18: whether the displayed Avg HR was edited away from what this HR trace implies. True only when the
    /// row carries CAPTURED strain or zones (so the graph/zones/Effort are from a real recording, not the
    /// typed value) AND the row's avgHr differs from the trace mean by more than a small tolerance. The
    /// tolerance absorbs ordinary rounding/bucketing drift so an unedited session never trips the note.
    private func avgHrEditedDisclosure(traceMean: Double) -> Bool {
        guard let avg = row.avgHr, row.strain != nil || row.zonesJSON != nil else { return false }
        return abs(Double(avg) - traceMean) > 3
    }

    // MARK: - HR zones

    @ViewBuilder private var zonesCard: some View {
        if let z = zoneMinutes, z.reduce(0, +) > 0 {
            let total = z.reduce(0, +)
            let busiest = z.indices.max(by: { z[$0] < z[$1] }) ?? 0
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("HR Zones",
                              overline: recordings.isEmpty ? (zonesFromImport ? "Whoop import" : "From strap HR") : "Recorded zones",
                              trailing: String(localized: "\(Int(total.rounded()))m in zone"))
                NoopCard(tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: 12) {
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { i in
                                    Rectangle()
                                        .fill(StrandPalette.hrZoneColor(i + 1))
                                        .frame(width: max(0, CGFloat(z[i] / total) * geo.size.width))
                                        .overlay {
                                            if i == busiest {
                                                Rectangle()
                                                    .strokeBorder(StrandPalette.textPrimary.opacity(0.85), lineWidth: 1.5)
                                            }
                                        }
                                }
                            }
                        }
                        .frame(height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "Heart-rate zone split: \((1...5).map { String(localized: "zone \($0) \(Int((z[$0 - 1] / total * 100).rounded())) percent") }.joined(separator: ", "))"))
                        Divider().overlay(StrandPalette.hairline)
                        HStack(spacing: 0) {
                            ForEach(0..<5, id: \.self) { i in
                                zoneStat(i + 1, minutes: z[i], total: total)
                            }
                        }
                        Text(!recordings.isEmpty
                             ? "Zones use the settings recorded during this workout. Gaps are not counted."
                             : zonesFromImport
                             ? "WHOOP's imported per-zone split for this session."
                             : "Time in each %HRmax zone, derived from the strap's heart rate over this window (approximate).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private func zoneStat(_ zone: Int, minutes: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StrandPalette.hrZoneColor(zone))
                    .frame(width: 9, height: 9)
                Text("Z\(zone)" as String).strandOverline()
            }
            Text("\(Int((minutes / max(total, 0.001) * 100).rounded()))%")
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(durationLabel(minutes * 60))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Effort contribution

    private func effortCard(strain: Double) -> some View {
        // The session's Effort as the signature liquid gauge: a `LiquidVessel` tinted Effort, filled to the
        // session's contribution on the user's selected scale, with the value counting up over it — the
        // same hero language as the Workouts list's Typical Effort gauge and the Sleep Rest hero. The
        // explanatory sentence keeps its place beside the gauge.
        let displayValue = UnitFormatter.effortValue(strain, scale: effortScale)
        let scaleMax: Double = effortScale == .whoop ? 21 : 100
        let fraction = max(0, min(1, displayValue / scaleMax))
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Effort", overline: "This session")
            NoopCard(tint: StrandPalette.effortColor) {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        // Static (posed) vessel — a compact liquid gauge inside a card, so it costs a single
                        // cached frame rather than a live canvas (same call as Trends' pip vessels).
                        LiquidVessel(value: fraction, tint: StrandPalette.effortColor, animated: false)
                            .frame(width: 88, height: 88)
                        VStack(spacing: 0) {
                            // The session's Effort contribution ticks up to its value — the NOOP signature.
                            CountUpText(value: displayValue,
                                        format: { String(format: "%.1f", $0) },
                                        font: StrandFont.rounded(28),
                                        color: StrandPalette.textPrimary)
                                .shadow(color: .black.opacity(0.5), radius: 5, y: 1)
                            Text(effortScale == .whoop ? "of 21" : "of 100")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Effort \(UnitFormatter.effortDisplay(strain, scale: effortScale)) \(effortScale == .whoop ? "of 21" : "of 100")"))
                    Spacer(minLength: 0)
                    Text("This session's contribution to the day's Effort, as captured during the workout.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 240, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Bits

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sourceBadge(_ source: String) -> some View {
        let (label, tint): (String, Color) = {
            switch WorkoutSource.classify(source) {
            case .whoop:    return (String(localized: "Whoop"), StrandPalette.accent)
            case .apple:    return (String(localized: "Apple"), StrandPalette.metricCyan)
            case .detected, .confirmed: return (String(localized: "Detected"), StrandPalette.metricPurple)
            case .manual:   return (String(localized: "Manual"), StrandPalette.statusWarning)
            case .hevy:     return (String(localized: "Hevy"), StrandPalette.zone2)
            case .lifting:  return (String(localized: "Lifting"), StrandPalette.zone2)
            case .activityFile: return (String(localized: "File"), StrandPalette.metricAmber)
            case .oura:     return (String(localized: "Oura"), StrandPalette.metricPurple)
            }
        }()
        return SourceBadge("\(label)", tint: tint)
    }

    // MARK: - Formatting (kept local, matching WorkoutsView's rhythm)

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMM yyyy"
        return f
    }()
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var timeFmt: DateFormatter { AppClock.hourMinuteFormatter() }
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var tooltipTime: DateFormatter { AppClock.hourMinuteFormatter() }

    private func dateLabel(_ ts: Int) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeLabel(_ ts: Int) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeRangeLabel(_ start: Int, _ end: Int) -> String {
        end > start ? "\(timeLabel(start))-\(timeLabel(end))" : timeLabel(start)
    }
    private func durationLabel(_ s: Double?) -> String {
        guard let s, s > 0 else { return "–" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(localized: "\(h)h \(m)m") }
        return String(localized: "\(m)m")
    }
    private func distanceLabel(_ m: Double?) -> String {
        guard let m, m > 0 else { return "–" }
        return UnitFormatter.distanceFromMeters(m, system: distanceUnitSystem)
    }
    private func grouped(_ v: Double) -> String {
        Self.intFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v.rounded()))"
    }
    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()
}

// MARK: - New design (NOOP Forge, prototype board "WorkoutFull")
//
// The same loaded values as the classic layout, arranged the way the redesign draws a session: the sport
// once as the title, every headline number in one card, the heart-rate curve with its zone split under it,
// the recovery as one number and the export as a row. Nothing here is computed differently.

extension WorkoutDetailView {
    var forgeBody: some View {
        ScreenScaffold(title: "\(WorkoutSource.localizedDisplaySport(row.sport))",
                       subtitle: "\(forgeWhen)", lazy: true) {
            GoalContributionNote(row: row)
            forgeStats
            routeCard
            WorkoutElevationCard(series: elevationSeries, elevation: elevation, sport: row.sport,
                                 system: distanceUnitSystem)
            ForEach(recordings) { recording in
                WorkoutRecordingSectionsView(timeline: recording.timeline,
                                             seconds: recording.row.durationS ?? 0,
                                             sport: recording.row.sport,
                                             elevation: elevationSeries)
            }
            forgeHeart
            forgeRecovery
            SessionRPECard(startTs: row.startTs, sport: row.sport,
                           durationS: row.durationS ?? Double(row.endTs - row.startTs))
            forgeExport
        }
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    /// "Sunday, 1 November · 18:36 to 20:03" in the reader's language.
    private var forgeWhen: String {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
        guard row.endTs > row.startTs else { return "\(day) · \(timeLabel(row.startTs))" }
        return String(localized: "\(day) · \(timeLabel(row.startTs)) to \(timeLabel(row.endTs))")
    }

    private func forgeTitle(_ title: LocalizedStringKey, _ trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private struct ForgeStat: Identifiable {
        let label: String
        let value: String
        var unit: String? = nil
        var tint: Color? = nil
        var pending = false
        var id: String { label }
    }

    /// The session's average or peak from its own heart-rate readings, for a workout whose source stored
    /// none (an Apple walk). Without it the stat said "no heart rate" above a full curve.
    static func heartFigure(_ readings: [Double], peak: Bool) -> Int? {
        let values = readings.filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        let figure = peak ? (values.max() ?? 0) : values.reduce(0, +) / Double(values.count)
        return Int(figure.rounded())
    }

    private var forgeStatList: [ForgeStat] {
        var out = [ForgeStat(label: String(localized: "time"), value: durationLabel(row.durationS))]
        if let m = row.distanceM, m > 0 {
            out.append(ForgeStat(label: String(localized: "distance"), value: distanceLabel(m)))
            out.append(showsSpeed ? ForgeStat(label: String(localized: "speed"), value: speedLabel)
                                  : ForgeStat(label: String(localized: "pace"), value: paceLabel))
        }
        let avgHeart = row.avgHr ?? Self.heartFigure(rawHeartBpm, peak: false)
        out.append(ForgeStat(label: String(localized: "avg heart"), value: avgHeart.map { "\($0)" } ?? "–",
                             unit: avgHeart != nil ? "bpm" : nil))
        if row.distanceM == nil || row.distanceM == 0 {
            let peakHeart = row.maxHr ?? Self.heartFigure(rawHeartBpm, peak: true)
            out.append(ForgeStat(label: String(localized: "peak heart"), value: peakHeart.map { "\($0)" } ?? "–",
                                 unit: peakHeart != nil ? "bpm" : nil))
        }
        if let strain = row.strain {
            let shown = effortScale == .whoop ? UnitFormatter.effortDisplay(strain, scale: effortScale)
                                              : "\(Int(UnitFormatter.effortValue(strain, scale: effortScale).rounded()))"
            out.append(ForgeStat(label: String(localized: "Effort"), value: shown,
                                 tint: StrandPalette.effortColor))
        }
        out.append(ForgeStat(label: String(localized: "kcal"), value: WorkoutEnergyDisplay.text(energy, marksEstimate: NoopVisualStyle.skin != .forge) ?? (energyPending ? "…" : "–"),
                             pending: energyPending && energy == nil))
        if WorkoutCatalog.isOnFoot(row.sport) {
            out.append(ForgeStat(label: String(localized: "steps"), value: steps.map { grouped(Double($0.count)) } ?? "–",
                                 pending: stepsPending))
        }
        return out
    }

    private var forgeSourceLine: String? {
        var parts: [String] = []
        switch WorkoutSource.classify(row.source) {
        case .whoop: parts.append(String(localized: "Whoop"))
        case .apple: parts.append(String(localized: "Apple"))
        case .detected, .confirmed: parts.append(String(localized: "Detected"))
        case .manual: parts.append(String(localized: "Manual"))
        case .hevy: parts.append(String(localized: "Hevy"))
        case .lifting: parts.append(String(localized: "Lifting"))
        case .activityFile: parts.append(String(localized: "File"))
        case .oura: parts.append(String(localized: "Oura"))
        }
        // Only an estimate earns a word here; the plain "kcal" fallback read as "Whoop · kcal".
        if let estimate = WorkoutEnergyDisplay.caption(energy) { parts.append(estimate) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var forgeStats: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3),
                          alignment: .leading, spacing: 16) {
                    ForEach(forgeStatList) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(stat.value)
                                    .font(StrandFont.rounded(22, weight: .bold))
                                    .foregroundStyle(stat.tint ?? StrandPalette.textPrimary)
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                if let unit = stat.unit {
                                    Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                if stat.pending { pendingIndicator }
                            }
                            Text(stat.label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let line = forgeSourceLine {
                    Text(line).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    @ViewBuilder private var forgeHeart: some View {
        if hrPoints.count > 1 {
            let values = hrPoints.map(\.value)
            let lo = max(0, (values.min() ?? 60) - 8)
            let hi = (values.max() ?? 180) + 8
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    forgeTitle("Heart rate", row.avgHr.map { String(localized: "avg \($0)") })
                    TrendChart(
                        points: hrPoints,
                        gradient: StrandPalette.effortGradient,
                        valueRange: lo...hi,
                        showsArea: true,
                        valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                        dateFormat: { Self.tooltipTime.string(from: $0) },
                        accessibilityLabel: String(localized: "Heart rate during \(WorkoutSource.displaySport(row.sport))"),
                        workoutTimeAxis: Date(timeIntervalSince1970: TimeInterval(row.startTs))...Date(timeIntervalSince1970: TimeInterval(row.endTs))
                    )
                    .frame(height: 150)
                    // The top axis label is drawn above the plot; room so it does not sit on the title.
                    .padding(.top, 18)
                    if let z = zoneMinutes, z.reduce(0, +) > 0 {
                        forgeZoneBand(z)
                    }
                    if avgHrEditedDisclosure(traceMean: values.reduce(0, +) / Double(values.count)) {
                        Text("The average above was edited. The graph, zones and Effort stay from the recorded session.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if let z = zoneMinutes, z.reduce(0, +) > 0 {
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    forgeTitle("Heart rate zones")
                    forgeZoneBand(z)
                }
            }
        } else if loaded {
            NoopCard { emptyNote("No heart-rate samples were recorded over this session's window.") }
        }
    }

    /// The zone split as one band, each zone in its colour, minutes under it. Empty zones are left out of
    /// the legend so the band and the words agree.
    private func forgeZoneBand(_ z: [Double]) -> some View {
        let total = z.reduce(0, +)
        let shown = (0..<min(5, z.count)).filter { z[$0] > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(shown, id: \.self) { i in
                        Rectangle().fill(StrandPalette.hrZoneColor(i + 1))
                            .frame(width: max(2, CGFloat(z[i] / total) * (geo.size.width - CGFloat(shown.count - 1) * 2)))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Heart-rate zone split: \((1...5).map { String(localized: "zone \($0) \(Int((z[$0 - 1] / total * 100).rounded())) percent") }.joined(separator: ", "))"))
            // Two columns of whole names: five zones in one row cut every name to three letters.
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(shown, id: \.self) { i in
                    HStack(spacing: 6) {
                        Circle().fill(StrandPalette.hrZoneColor(i + 1)).frame(width: 8, height: 8)
                        Text(LiveHeartRateStyle.zoneName(i + 1)).font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(durationLabel(z[i] * 60)).font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                    }
                }
            }
            Text(!recordings.isEmpty
                 ? "Zones use the settings recorded during this workout. Gaps are not counted."
                 : zonesFromImport
                 ? "WHOOP's imported per-zone split for this session."
                 : "Time in each heart-rate zone, from the strap's pulse during this session. Approximate.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var forgeRecovery: some View {
        if let recovery = heartRateRecovery {
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    forgeTitle("Recovery after", String(localized: "Peak \(recovery.endHR) bpm"))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: recovery.after1Minute.map { $0 > 0 ? "−\($0)" : "\(-$0)" } ?? "–")
                            .font(StrandFont.rounded(34, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("bpm in the first minute").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 16) {
                        forgeRecoveryLater(String(localized: "after 2 min"), recovery.after2Minutes)
                        forgeRecoveryLater(String(localized: "after 5 min"), recovery.after5Minutes)
                    }
                    Text("How far your heart rate fell after the end of the effort. A larger drop is a sign of fitness.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func forgeRecoveryLater(_ label: String, _ value: Int?) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: value.map { $0 > 0 ? "−\($0) bpm" : "\(-$0) bpm" } ?? "–")
                .font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var forgeExport: some View {
        if route.count >= 2 || !hrPoints.isEmpty {
            Button { showRouteExport = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up")
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(StrandPalette.surfaceInset))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Export workout").font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                        Text("For Strava, Garmin Connect and other apps").font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                    .fill(StrandPalette.surfaceRaised))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .confirmationDialog("Export workout", isPresented: $showRouteExport, titleVisibility: .visible) {
                if route.count >= 2 {
                    Button("GPX — Strava, Garmin, most apps") { exportWorkout(.gpx) }
                }
                Button("FIT — Garmin Connect") { exportWorkout(.fit) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: - Route map (#524)
//
// A MapKit map of the captured route polyline, drawn with start (green) + end (red) markers — the Apple
// analogue of Android's `RouteCanvas`, but on real map tiles. Built as a platform-bridged representable
// around `MKMapView` so it runs on BOTH iOS 17 and macOS 13 (SwiftUI's newer `Map { MapPolyline }` needs
// iOS 17 / macOS 14, and the macOS deployment target is 13). The map is offline-capable: MapKit caches
// tiles locally and the route itself is on-device — NOOP never sends the route anywhere.

#if canImport(MapKit) && canImport(UIKit)
import UIKit
typealias RouteMapRepresentable = UIViewRepresentable
#elseif canImport(MapKit) && canImport(AppKit)
import AppKit
typealias RouteMapRepresentable = NSViewRepresentable
#endif

#if canImport(MapKit)
struct WorkoutRouteMap: RouteMapRepresentable {
    let points: [RouteMath.LatLng]
    var segments: [[RouteMath.LatLng]]? = nil

    private var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeMap(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        configure(map)
        return map
    }

    /// Draw the polyline + start/end pins and frame the route. Replaces any existing overlays so a
    /// re-render doesn't stack them.
    private func configure(_ map: MKMapView) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        let coords = coordinates
        guard coords.count >= 2 else { return }
        let lines = (segments ?? [points]).filter { $0.count >= 2 }.map { segment in
            let coordinates = segment.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }
        guard let firstLine = lines.first else { return }
        map.addOverlays(lines)

        guard let first = coords.first, let last = coords.last else { return }
        let start = MKPointAnnotation(); start.coordinate = first; start.title = String(localized: "Start")
        let end = MKPointAnnotation(); end.coordinate = last; end.title = String(localized: "Finish")
        map.addAnnotations([start, end])

        // Frame the whole route with a little padding so the line isn't flush to the edges.
        let rect = lines.dropFirst().reduce(firstLine.boundingMapRect) { $0.union($1.boundingMapRect) }
        let inset = UIEdgeInsetsLikePadding
        map.setVisibleMapRect(rect, edgePadding: inset, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            // Effort-amber world, matching the rest of the workout detail. A platform colour (the
            // renderer needs a UIColor/NSColor, not a SwiftUI Color); kept close to the Effort accent.
            r.strokeColor = RoutePlatformColor.effort
            r.lineWidth = 4
            r.lineJoin = .round
            r.lineCap = .round
            return r
        }
    }

    #if canImport(UIKit)
    private var UIEdgeInsetsLikePadding: UIEdgeInsets { UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ map: MKMapView, context: Context) { configure(map) }
    #elseif canImport(AppKit)
    private var UIEdgeInsetsLikePadding: NSEdgeInsets { NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) { configure(map) }
    #endif
}

/// The route stroke colour as a platform colour (MapKit's renderer can't take a SwiftUI `Color`). A fixed
/// Effort-amber so it reads in the same colour world as the rest of the screen on both platforms.
private enum RoutePlatformColor {
    #if canImport(UIKit)
    static let effort = UIColor(red: 0.98, green: 0.62, blue: 0.16, alpha: 1.0)
    #elseif canImport(AppKit)
    static let effort = NSColor(red: 0.98, green: 0.62, blue: 0.16, alpha: 1.0)
    #endif
}
#else
/// Platforms without MapKit (none we ship, but keeps the type resolvable): no route map.
struct WorkoutRouteMap: View {
    let points: [RouteMath.LatLng]
    var segments: [[RouteMath.LatLng]]? = nil
    var body: some View { Color.clear }
}
#endif

#if DEBUG
#Preview("Workout Detail") {
    NavigationStack {
        WorkoutDetailView(row: WorkoutRow(
            startTs: Int(Date().timeIntervalSince1970) - 3600,
            endTs: Int(Date().timeIntervalSince1970),
            sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
            avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
            zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil, steps: nil))
            .environmentObject(Repository(deviceId: "preview"))
    }
    .frame(width: 1040, height: 940)
    .preferredColorScheme(.dark)
}
#endif
