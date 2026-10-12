import SwiftUI
import StrandDesign
import StrandAnalytics

// HealthspanSection.swift — fork feature "AgeLess" (backlog plan HEALTHSPAN_AGE_PLAN, spec S6). While the
// experiment is on, a compact AgeLess card takes Body Age's place on Health, so the screen states one age;
// tapping it opens the full AgeLess screen (HealthspanDetailView).
//
// One resolver (`HealthspanSnapshot.load`) reads the stored window and 30-day inputs and runs every week
// through the engine; every number on both screens comes from those results, so none can disagree.

/// One week as the screens show it.
struct HealthspanWeek {
    let day: String
    let inputs: HealthspanEngine.Inputs
    let recentInputs: HealthspanEngine.Inputs?
    let result: HealthspanEngine.Result
    let pace: Double?
    let coveredDays: Int

    var isProvisional: Bool { coveredDays < HealthspanWindow.ageWindowDays }
    var levers: [HealthspanEngine.Lever] { HealthspanEngine.levers(inputs) }
}

/// Every stored week, oldest first, resolved once.
struct HealthspanSnapshot {
    let weeks: [HealthspanWeek]
    var latest: HealthspanWeek { weeks[weeks.count - 1] }

    @MainActor
    static func load(repo: Repository, age: Int, sex: HealthspanEngine.Sex) async -> HealthspanSnapshot? {
        let source = Repository.whoopSource
        func byDay(_ key: String) async -> [String: Double] {
            Dictionary(await repo.exploreSeries(key: key, source: source).map { ($0.day, $0.value) },
                       uniquingKeysWith: { _, b in b })
        }
        let days = await repo.exploreSeries(key: IntelligenceEngine.healthspanAgeKey, source: source).map(\.day)
        var window: [HealthspanEngine.Component: [String: Double]] = [:]
        var recent: [HealthspanEngine.Component: [String: Double]] = [:]
        for c in HealthspanEngine.Component.allCases {
            window[c] = await byDay(IntelligenceEngine.healthspanInputKey(c))
            recent[c] = await byDay(IntelligenceEngine.healthspanRecentInputKey(c))
        }
        let paces = await byDay(IntelligenceEngine.healthspanPaceKey)
        let covered = await byDay(IntelligenceEngine.healthspanCoveredDaysKey)
        func inputs(_ series: [HealthspanEngine.Component: [String: Double]], _ day: String) -> HealthspanEngine.Inputs? {
            var x = HealthspanEngine.Inputs(age: Double(age), sex: sex)
            var any = false
            for c in HealthspanEngine.Component.allCases {
                let v = series[c]?[day]; x.set(c, v); any = any || v != nil
            }
            return any ? x : nil
        }
        let weeks = days.compactMap { day -> HealthspanWeek? in
            guard let x = inputs(window, day), let result = HealthspanEngine.compute(x) else { return nil }
            return HealthspanWeek(day: day, inputs: x, recentInputs: inputs(recent, day), result: result,
                                  pace: paces[day], coveredDays: Int(covered[day] ?? 0))
        }
        return weeks.isEmpty ? nil : HealthspanSnapshot(weeks: weeks)
    }
}

struct HealthspanSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var snapshot: HealthspanSnapshot?
    @State private var loaded = false
    @State private var showsDetail = false

    private var sex: HealthspanEngine.Sex? { HealthspanEngine.Sex(profileValue: profile.sex) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("AgeLess", overline: "Weekly",
                          trailing: snapshot?.latest.isProvisional == true ? String(localized: "Provisional") : nil)
            if sex == nil {
                ComingSoon(what: "Set your sex in your profile to see your AgeLess age.", symbol: "person")
            } else if let snapshot {
                Button { showsDetail = true } label: { card(snapshot.latest) }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("See details"))
            } else if loaded {
                ComingSoon(what: "Your AgeLess age appears after 30 nights of sleep data.", symbol: "hourglass")
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

    private func load() async {
        if let sex { snapshot = await HealthspanSnapshot.load(repo: repo, age: profile.age, sex: sex) }
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
        case .zone13: return String(localized: "Time in zones 1–3")
        case .zone45: return String(localized: "Time in zones 4–5")
        case .strength: return String(localized: "Strength activity")
        case .vo2max: return String(localized: "VO₂max")
        case .restingHR: return String(localized: "Resting heart rate")
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

/// The headline both screens share: the age gauge, then Pace of Aging in a pill below it unless the screen
/// shows the pace on its own slider.
struct HealthspanTopRow: View {
    let week: HealthspanWeek
    var showsPace = true
    @State private var progress = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: NoopMetrics.space3) {
            HealthspanAgeGauge(age: week.result.healthspanAge, actualAge: week.result.chronologicalAge, progress: progress)
                .frame(maxWidth: .infinity)
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
            Text("Pace of Aging")
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
