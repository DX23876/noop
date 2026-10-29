import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanSection.swift — fork feature "AgeLess" (backlog plan HEALTHSPAN_AGE_PLAN, spec S6). While the
// experiment is on, a compact AgeLess card takes Body Age's place on Health, so the screen states one age;
// tapping it opens the full AgeLess screen (HealthspanDetailView).
//
// One resolver (`HealthspanSnapshot.load`) reads the stored window and 30-day inputs and runs every week
// through the engine; every number on both screens comes from those results, so none can disagree.

/// What the AgeLess card says without an age, decided from the stored gap alone.
enum HealthspanEmptyReason: Equatable {
    /// No daily steps at all: a strap without a step counter and nothing from the phone.
    case steps
    /// Another core measure the band supplies is missing.
    case measures([HealthspanEngine.Component])
    /// Every measure is there, the nights are not yet; the count so far.
    case nights(Int)
    /// Nothing stored that says why.
    case unknown

    init(_ gap: HealthspanWindow.Gap?) {
        guard let gap else { self = .unknown; return }
        if gap.missing.contains(.dailySteps) {
            self = .steps
        } else if !gap.missing.isEmpty {
            self = .measures(gap.missing)
        } else if gap.nights < HealthspanWindow.minimumNights {
            self = .nights(gap.nights)
        } else {
            self = .unknown
        }
    }
}

struct HealthspanSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var snapshot: HealthspanSnapshot?
    @State private var emptyReason = HealthspanEmptyReason.unknown
    @State private var loaded = false
    @State private var showsDetail = false

    private var sex: HealthspanEngine.Sex? { HealthspanEngine.Sex(profileValue: profile.sex) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("AgeLess", overline: "Weekly",
                          trailing: snapshot?.latest.isProvisional == true ? String(localized: "Provisional") : String(localized: "Beta"))
            if sex == nil {
                ComingSoon(what: "Set your sex in your profile to see your AgeLess age.", symbol: "person")
            } else if let snapshot {
                Button { showsDetail = true } label: { card(snapshot.latest) }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("See details"))
            } else if loaded {
                emptyState
            } else {
                ComingSoon.loading("Reading your AgeLess age…", title: "AgeLess", symbol: "hourglass")
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .sheet(isPresented: $showsDetail) {
            if let snapshot {
                NavigationStack { HealthspanDetailView(snapshot: snapshot) }
                    .tint(StrandPalette.agelessYoungDeep)
                    #if os(macOS)
                    .frame(width: 900, height: 820)
                    #endif
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch emptyReason {
        case .steps:
            ComingSoon(what: "AgeLess needs your daily steps. Bring them in from Apple Health, or set up the step estimate in Settings.",
                       symbol: "figure.walk")
        case .measures(let missing):
            let names = missing.map(HealthspanSection.componentName).formatted(.list(type: .and))
            ComingSoon(what: "AgeLess still needs: \(names)", symbol: "hourglass")
        case .nights(let nights):
            ComingSoon(what: "Your AgeLess age appears after 30 nights of sleep data. \(nights) so far.",
                       symbol: "hourglass")
        case .unknown:
            ComingSoon(what: "Your AgeLess age appears after 30 nights of sleep data.", symbol: "hourglass")
        }
    }

    private func load() async {
        if let sex {
            snapshot = await HealthspanSnapshot.load(repo: repo, age: profile.age, sex: sex)
            emptyReason = snapshot == nil ? HealthspanEmptyReason(await HealthspanSnapshot.gap(repo: repo)) : .unknown
        }
        loaded = true
    }

    private func card(_ w: HealthspanWeek) -> some View {
        VStack(spacing: NoopMetrics.space3) {
            HealthspanTopRow(week: w)
            HStack {
                Text("See details").font(StrandFont.subhead)
                Spacer()
                Image(systemName: "chevron.right").font(StrandFont.caption)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(minHeight: 44)
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity)
        .background { FrostedCardSurface(tint: StrandPalette.agelessYoungDeep, cornerRadius: NoopMetrics.cardRadius) }
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }

    // MARK: Formatting (shared by the AgeLess screens)

    static func years(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }

    /// "−0.9" / "+1.2" / "0.0": a signed figure for places where the unit is printed beside it.
    static func signedNumber(_ v: Double) -> String {
        let n = abs(v).formatted(.number.precision(.fractionLength(1)))
        if abs(v) < 0.05 { return n }
        return v < 0 ? "−" + n : "+" + n
    }

    static func signedYears(_ v: Double) -> String {
        let n = abs(v).formatted(.number.precision(.fractionLength(1)))
        if abs(v) < 0.05 { return String(localized: "\(n) yrs") }
        return v < 0 ? String(localized: "−\(n) yrs") : String(localized: "+\(n) yrs")
    }

    static func sinceLine(_ change: Double, since: Date?) -> String {
        let n = abs(change).formatted(.number.precision(.fractionLength(1)))
        let d = since?.formatted(.dateTime.day().month(.abbreviated)) ?? ""
        if abs(change) < 0.05 { return String(localized: "Unchanged since \(d)") }
        return change < 0 ? String(localized: "\(n) yrs younger since \(d)") : String(localized: "\(n) yrs older since \(d)")
    }

    static func paceState(_ pace: Double) -> String {
        switch HealthspanEngine.PaceClass(pace: pace) {
        case .reversing: return String(localized: "REVERSING")
        case .slowing: return String(localized: "SLOWING")
        case .steady: return String(localized: "STEADY")
        case .accelerating: return String(localized: "ACCELERATING")
        }
    }

    /// Under a measure's bar: what it stands on, or how to supply a missing VO₂max or lean mass. An entered
    /// VO₂max older than six months asks to be measured again.
    static func note(_ c: HealthspanEngine.Component, week: HealthspanWeek, today: String) -> String? {
        if c == .vo2max, week.inputs.vo2max == nil || week.vo2Source == nil {
            guard let floor = week.vo2Floor else {
                return String(localized: "Wear your Apple Watch on walks, or enter a lab value.")
            }
            return String(localized: "Wear your Apple Watch on walks, or enter a lab value. Your long walks put it at \(value(.vo2max, floor)) or more.")
        }
        if c == .leanMass, week.inputs.leanMassPct == nil {
            return String(localized: "Add your body fat on the Body page.")
        }
        // Every week since the AI-23 to AI-26 rebuilds carries its basis.
        guard let line = week.basis(c, today: today) else { return nil }
        let window = String(localized: "6 months")
        switch line.kind {
        case .days(let count, let of):
            switch c {
            case .dailySteps: return String(localized: "Days: \(count) of \(of) · \(window)")
            default: return String(localized: "Nights: \(count) of \(of) · \(window)")
            }
        case .zoneDays(let count):
            return String(localized: "Days measured: \(count) · \(window)")
        case .sessions(let count):
            return String(localized: "Sessions: \(count) · \(window)")
        case .vo2max(let source, _, let latestDay):
            let date = shortDate(latestDay)
            // A measured value below what the long walks allow is worth saying, not correcting.
            let line = vo2Line(source: source, date: date, latestDay: latestDay, today: today)
            if let floor = week.vo2Floor, let v = week.inputs.vo2max, floor > v + 0.5 {
                return String(localized: "\(line) · long walks suggest at least \(value(.vo2max, floor))")
            }
            return line
        case .bodyFat(let day):
            return String(localized: "Body fat from \(shortDate(day))")
        }
    }

    /// Where a week's VO₂max came from, with its day.
    private static func vo2Line(source: HealthspanVO2.Source, date: String, latestDay: String,
                                today: String) -> String {
        switch source {
        case .manual:
            let stale = latestDay < HealthspanWindow.dayKey(today, plus: -HealthspanWindow.ageWindowDays)
            return stale ? String(localized: "Entered \(date) · measure again?")
                : String(localized: "Entered \(date)")
        case .appleHealth:
            return String(localized: "From Apple Health, \(date)")
        }
    }

    /// Whether the measure's basis is too thin to lean on (`HealthspanBasis`).
    static func isThin(_ c: HealthspanEngine.Component, week: HealthspanWeek, today: String) -> Bool {
        week.inputs.value(c) != nil && week.basis(c, today: today)?.isThin == true
    }

    private static func shortDate(_ day: String) -> String {
        date(day)?.formatted(.dateTime.day().month(.abbreviated)) ?? day
    }

    static func domainName(_ d: HealthspanDomain) -> String {
        switch d {
        case .sleep: return String(localized: "Sleep")
        case .activity: return String(localized: "Activity")
        case .fitness: return String(localized: "Fitness")
        }
    }

    static func componentName(_ c: HealthspanEngine.Component) -> String {
        switch c {
        case .sleepDuration: return String(localized: "Hours of sleep")
        case .sleepConsistency: return String(localized: "Sleep consistency")
        case .dailySteps: return String(localized: "Daily steps")
        // Named for what the studies measured, not "zones": the app's own zones are % of maximum heart rate,
        // these follow the heart-rate reserve.
        case .zone13: return String(localized: "Moderate activity")
        case .zone45: return String(localized: "Vigorous activity")
        case .strength: return String(localized: "Strength activity")
        case .vo2max: return String(localized: "VO₂max")
        // Not the app's resting HR (the night's lowest five minutes): the whole-sleep mean the method uses.
        case .restingHR: return String(localized: "Average sleeping heart rate")
        case .leanMass: return String(localized: "Lean body mass")
        }
    }

    static func value(_ c: HealthspanEngine.Component, _ v: Double) -> String {
        let whole = v.formatted(.number.precision(.fractionLength(0)))
        let one = v.formatted(.number.precision(.fractionLength(1)))
        switch c {
        case .sleepDuration: return String(localized: "\(one) h")
        case .sleepConsistency, .leanMass: return (v / 100).formatted(.percent.precision(.fractionLength(0)))
        case .dailySteps: return whole
        case .zone13, .zone45, .strength: return String(localized: "\(whole) min/wk")
        case .vo2max: return one
        case .restingHR: return String(localized: "\(whole) bpm")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date? { dayFormatter.date(from: day) }
}

/// The headline both screens share: the age gauge, how many measures it stands on when some are missing, then
/// Aging speed in a pill below it unless the screen shows the pace on its own slider.
struct HealthspanTopRow: View {
    let week: HealthspanWeek
    var showsPace = true
    @State private var progress = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: NoopMetrics.space3) {
            HealthspanAgeGauge(age: week.result.healthspanAge, actualAge: week.result.chronologicalAge, progress: progress)
                .frame(maxWidth: .infinity)
            let used = week.result.componentsUsed, all = HealthspanEngine.Component.allCases.count
            if used < all {
                Text("Based on \(used) of \(all) measures")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if showsPace, let pace = week.pace { pacePill(pace) }
        }
        .onAppear {
            if reduceMotion { progress = 1 } else { withAnimation(.easeOut(duration: 0.9)) { progress = 1 } }
        }
    }

    private func pacePill(_ pace: Double) -> some View {
        let colour = pace <= 1 ? StrandPalette.agelessYoungDeep : StrandPalette.agelessOld
        return HStack(spacing: NoopMetrics.space2) {
            if HealthspanEngine.PaceClass(pace: pace) != .steady {
                Image(systemName: pace < 1 ? "arrow.down" : "arrow.up")
            }
            Text("Aging speed")
            Text(verbatim: HealthspanPaceSlider.paceText(pace)).monospacedDigit()
        }
        .font(StrandFont.subhead.weight(.semibold))
        .foregroundStyle(pace <= 1 ? StrandPalette.agelessYoungDeep.legibleText : StrandPalette.agelessOld.legibleText)
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space2)
        .background(Capsule().fill(colour.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

extension Repository: HealthspanSeriesReading {
    /// The strap's computed AgeLess series, as the screens always read them.
    func healthspanSeries(key: String, days: Int?) async -> [(day: String, value: Double)] {
        await exploreSeries(key: key, source: Repository.whoopSource, days: days ?? 4000)
    }
}
