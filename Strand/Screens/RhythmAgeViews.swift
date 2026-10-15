import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// RhythmAgeViews.swift — fork feature "Daily rhythm" (CosinorAge beta, WHOOP 5.0 and MG), shaped like AgeLess and
// written for people, not analysts: the rhythm age on AgeLess's own gauge (an age is what people remember, as with
// "heart age"), the day as 24 hourly bars against the study's typical day with one sentence saying what that shows,
// three plain comparisons without units, the one step that helps most, the history, and an About sheet with its own
// drawn motif. Reads the readout the daily pass stored (IntelligenceEngine+RhythmAge.swift); scores nothing itself.

// MARK: - Stored readout

enum RhythmAgeSnapshot: Equatable {
    struct Reading: Equatable {
        let day: String
        let advance: Double
        let mesor: Double
        let amplitude: Double
        let peakHour: Double
        let sdYears: Double?
        /// Average movement per local clock hour on that day's window, 24 entries, nil where unobserved.
        var hourly: [Double?] = Array(repeating: nil, count: 24)
    }

    case empty
    case collecting(hours: Double)
    case reading(Reading)

    private typealias K = IntelligenceEngine

    /// The newest scored day, keyed `series[key][day]`. Only that day counts, so an older reading never stands
    /// in for a newer day that is still collecting.
    static func latest(_ series: [String: [String: Double]]) -> RhythmAgeSnapshot {
        guard let day = series[K.rhythmHoursKey]?.keys.max(), let hours = series[K.rhythmHoursKey]?[day] else {
            return .empty
        }
        guard let advance = series[K.rhythmAdvanceKey]?[day], let mesor = series[K.rhythmMesorKey]?[day],
              let amplitude = series[K.rhythmAmplitudeKey]?[day], let peak = series[K.rhythmPeakKey]?[day] else {
            return .collecting(hours: hours)
        }
        return .reading(Reading(day: day, advance: advance, mesor: mesor, amplitude: amplitude, peakHour: peak,
                                sdYears: series[K.rhythmSDKey]?[day],
                                hourly: (0..<24).map { series[K.rhythmHourKey($0)]?[day] }))
    }

    /// Every stored rhythm age, oldest first, for the history chart.
    static func history(_ series: [String: [String: Double]]) -> [(day: String, advance: Double)] {
        (series[K.rhythmAdvanceKey] ?? [:]).sorted { $0.key < $1.key }.map { (day: $0.key, advance: $0.value) }
    }

    @MainActor
    static func load(repo: Repository) async -> (RhythmAgeSnapshot, [(day: String, advance: Double)]) {
        var series: [String: [String: Double]] = [:]
        for key in IntelligenceEngine.rhythmKeys {
            series[key] = Dictionary(await repo.exploreSeries(key: key, source: Repository.whoopSource, days: 400)
                .map { ($0.day, $0.value) }, uniquingKeysWith: { _, b in b })
        }
        return (latest(series), history(series))
    }
}

// MARK: - Words

enum RhythmAgeText {
    private typealias Part = RhythmAge.PartOfDay

    /// One or two plain sentences on what the hour chart shows: the part of the day that matches the study best,
    /// then the part or parts where movement falls well short. nil when the day is not fully observed.
    static func daySentence(_ hourly: [Double?]) -> String? {
        let levels = RhythmAge.partLevels(hourly)
        guard levels.count == Part.allCases.count else { return nil }
        let below = Part.allCases.filter { levels[$0] == .below }
        if below.count == Part.allCases.count {
            return String(localized: "You move much less than most people all day.")
        }
        let strong = Part.allCases.first { levels[$0] == .above } ?? Part.allCases.first { levels[$0] == .typical }
        var sentences: [String] = []
        if let strong { sentences.append(goodPart(strong, more: levels[strong] == .above)) }
        if !below.isEmpty { sentences.append(lessIn(below)) }
        return sentences.joined(separator: " ")
    }

    private static func goodPart(_ p: Part, more: Bool) -> String {
        switch (p, more) {
        case (.morning, false): return String(localized: "In the morning you move like most people.")
        case (.morning, true): return String(localized: "In the morning you move more than most people.")
        case (.afternoon, false): return String(localized: "In the afternoon you move like most people.")
        case (.afternoon, true): return String(localized: "In the afternoon you move more than most people.")
        case (.evening, false): return String(localized: "In the evening you move like most people.")
        case (.evening, true): return String(localized: "In the evening you move more than most people.")
        }
    }

    private static func lessIn(_ parts: [Part]) -> String {
        switch Set(parts) {
        case [.morning]: return String(localized: "In the morning much less.")
        case [.afternoon]: return String(localized: "In the afternoon much less.")
        case [.evening]: return String(localized: "In the evening much less.")
        case [.morning, .afternoon]: return String(localized: "In the morning and afternoon much less.")
        case [.morning, .evening]: return String(localized: "In the morning and evening much less.")
        default: return String(localized: "In the afternoon and evening much less.")
        }
    }

    /// The one concrete step: where movement is missing, or a nudge to keep going.
    static func lever(_ r: RhythmAgeSnapshot.Reading) -> String {
        let levels = RhythmAge.partLevels(r.hourly)
        if levels.count == RhythmAge.PartOfDay.allCases.count,
           let first = RhythmAge.PartOfDay.allCases.first(where: { levels[$0] == .below }),
           levels.values.contains(where: { $0 != .below }) {
            switch first {
            case .morning: return String(localized: "Get up for a few minutes every hour in the morning. That is where you're missing movement.")
            case .afternoon: return String(localized: "Get up for a few minutes every hour in the afternoon. That is where you're missing movement.")
            case .evening: return String(localized: "Get up for a few minutes every hour in the evening. That is where you're missing movement.")
            }
        }
        if RhythmAge.movementLevel(mesorMg: r.mesor) == .below || RhythmAge.contrastLevel(amplitudeMg: r.amplitude) == .below {
            return String(localized: "Get up for a few minutes every hour of the day. That gives your day more movement and a clearer rhythm.")
        }
        return String(localized: "Your day moves like most people's. Keep it that way.")
    }

    /// "9 AM to 12 PM" / "9 bis 12 Uhr" in the reader's own clock style.
    static func window(_ start: Int, length: Int = 3) -> String {
        String(localized: "\(hour(start)) to \(hour(start + length))")
    }

    static func hour(_ h: Int) -> String {
        let date = Calendar.current.date(bySettingHour: h % 24, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

// MARK: - Health card

struct RhythmAgeSection: View {
    @EnvironmentObject var repo: Repository
    @State private var snapshot: RhythmAgeSnapshot?
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Daily rhythm", overline: "Weekly", trailing: String(localized: "Beta"))
            Button { showsDetail = true } label: {
                VStack(spacing: NoopMetrics.space3) {
                    RhythmAgeHero(snapshot: snapshot, compact: true)
                    HStack {
                        Text("See details").font(StrandFont.subhead)
                        Spacer()
                        Image(systemName: "chevron.right").font(StrandFont.caption)
                    }
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(minHeight: 44)
                }
                .agelessCard()
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("See details"))
        }
        .task(id: repo.refreshSeq) { snapshot = await RhythmAgeSnapshot.load(repo: repo).0 }
        .sheet(isPresented: $showsDetail) {
            NavigationStack { RhythmAgeDetailView(showsDone: true) }
                .tint(StrandPalette.agelessYoungDeep)
                #if os(macOS)
                .frame(width: 720, height: 820)
                #endif
        }
    }
}

/// The rhythm age on AgeLess's gauge, or what is missing. Shared by the Health card and the screen; the card adds
/// the one-line summary of the day.
struct RhythmAgeHero: View {
    let snapshot: RhythmAgeSnapshot?
    var compact = false
    @EnvironmentObject var profile: ProfileStore
    @State private var progress = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch snapshot {
        case nil:
            Text("Reading your daily rhythm…")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        case .empty?:
            VStack(spacing: NoopMetrics.space3) {
                RhythmIllustration().frame(height: compact ? 96 : 140)
                Text("Your daily rhythm appears after three days of wearing a WHOOP 5.0 or MG day and night.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .collecting(let hours)?:
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("\(Int(hours.rounded(.down))) of 72 hours collected")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                ProgressView(value: min(hours, 72), total: 72)
                    .tint(StrandPalette.agelessYoung)
                Text("Wear your strap day and night, and charge it at different times so no part of the day stays empty.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .reading(let r)?:
            let actual = Double(max(profile.age, 1))
            VStack(spacing: NoopMetrics.space2) {
                Text("Rhythm age · last 7 days")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                HealthspanAgeGauge(age: actual + r.advance, actualAge: actual, progress: progress)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Rhythm age \(HealthspanSection.years(actual + r.advance)), \(HealthspanSection.years(abs(r.advance))) \(Text(r.advance > 0 ? "years older" : "years younger"))"))
                if compact, let sentence = RhythmAgeText.daySentence(r.hourly) {
                    Text(sentence)
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear {
                if reduceMotion { progress = 1 } else { withAnimation(.easeOut(duration: 0.9)) { progress = 1 } }
            }
        }
    }
}

// MARK: - Your day

/// The week's average movement per clock hour as 24 bars, the study's typical day as a dashed line, and one
/// sentence saying what that shows. A straight 24-hour bar chart reads more accurately than a round clock
/// (Waldner et al., IEEE VIS 2019). The movement axis carries no numbers: it has no everyday unit.
struct RhythmDayCard: View {
    let hourly: [Double?]

    private var top: Double { max(1, (hourly.compactMap { $0 } + RhythmAge.typicalDay).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Your day").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Movement per hour, average of the week")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            chart.frame(height: 150).padding(.top, NoopMetrics.space2)
            HStack(spacing: NoopMetrics.space4) {
                HStack(spacing: NoopMetrics.space1) {
                    RoundedRectangle(cornerRadius: 2).fill(StrandPalette.agelessYoung).frame(width: 10, height: 10)
                    Text("You")
                }
                HStack(spacing: NoopMetrics.space1) {
                    Capsule().stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 16, height: 2)
                    Text("Typical day in the study")
                }
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .accessibilityElement(children: .combine)
            if let sentence = RhythmAgeText.daySentence(hourly) {
                Text(sentence)
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NoopMetrics.space2)
            }
        }
        .agelessCard()
    }

    private var chart: some View {
        Chart {
            ForEach(0..<24, id: \.self) { h in
                if let v = hourly[h] {
                    RectangleMark(xStart: .value("Hour", Double(h) + 0.12), xEnd: .value("Hour", Double(h) + 0.88),
                                  yStart: .value("Movement", 0), yEnd: .value("Movement", v))
                        .foregroundStyle(StrandPalette.agelessYoung)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
            ForEach(0..<24, id: \.self) { h in
                LineMark(x: .value("Hour", Double(h) + 0.5), y: .value("Movement", RhythmAge.typicalDay[h]),
                         series: .value("Line", "typical"))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...top * 1.05)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let h = value.as(Double.self) { Text(RhythmAgeText.hour(Int(h))) }
                }
            }
        }
        .accessibilityLabel(Text("Movement per hour, average of the week"))
    }
}

// MARK: - Three-step comparisons

/// A measure placed on three plain steps ("less", "like most people", "more"), the wearer's step lit: coral when
/// it trails the study, AgeLess cyan otherwise. No figures and no units.
struct RhythmStepRow: View {
    let title: LocalizedStringKey
    let steps: [LocalizedStringKey]
    let selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title).font(StrandFont.subhead.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: NoopMetrics.space1) {
                ForEach(steps.indices, id: \.self) { i in
                    let on = i == selected
                    let tone = selected == 0 ? StrandPalette.agelessOld : StrandPalette.agelessYoungDeep
                    Text(steps[i])
                        .font(StrandFont.caption.weight(on ? .semibold : .regular))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(on ? tone.legibleText : StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .padding(.horizontal, NoopMetrics.space1)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? tone.opacity(0.16) : StrandPalette.textTertiary.opacity(0.10)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(steps[selected]))
    }

    static func index(_ level: RhythmAge.Level) -> Int {
        switch level {
        case .below: return 0
        case .typical: return 1
        case .above: return 2
        }
    }
}

// MARK: - Detail screen

/// The full daily-rhythm screen: the rhythm age on AgeLess's gauge, the day hour by hour against the study, three
/// plain comparisons, the one step that helps most, the history, and the About sheet. Reached from the Health card
/// (a sheet, `showsDone`) and from More › Health & Body.
struct RhythmAgeDetailView: View {
    var showsDone = false
    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: RhythmAgeSnapshot?
    @State private var history: [(day: String, advance: Double)] = []
    @State private var showsAbout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space6) {
                RhythmAgeHero(snapshot: snapshot).agelessCard()
                if case .reading(let r)? = snapshot {
                    RhythmDayCard(hourly: r.hourly)
                    comparisons(r)
                    lever(r)
                    if history.count >= 2 { trend }
                }
                Button { showsAbout = true } label: { Label("About the rhythm age", systemImage: "info.circle") }
                    .buttonStyle(.plain)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .padding(NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle(Text("Daily rhythm"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsAbout = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel(Text("About the rhythm age"))
            }
            if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $showsAbout) { RhythmAgeAboutSheet() }
        .task(id: repo.refreshSeq) { (snapshot, history) = await RhythmAgeSnapshot.load(repo: repo) }
    }

    private func comparisons(_ r: RhythmAgeSnapshot.Reading) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            RhythmStepRow(title: "Movement over the day", steps: ["Less", "Like most people", "More"],
                          selected: RhythmStepRow.index(RhythmAge.movementLevel(mesorMg: r.mesor)))
            RhythmStepRow(title: "Day vs night", steps: ["Hardly any difference", "Like most people", "Clear difference"],
                          selected: RhythmStepRow.index(RhythmAge.contrastLevel(amplitudeMg: r.amplitude)))
            if let start = RhythmAge.busiestWindowStart(r.hourly) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Most active").font(StrandFont.subhead.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(RhythmAgeText.window(start))
                        .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .agelessCard()
    }

    private func lever(_ r: RhythmAgeSnapshot.Reading) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Label("What helps most", systemImage: "figure.walk")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
            Text(RhythmAgeText.lever(r))
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .fill(StrandPalette.agelessYoung.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }

    private var trend: some View {
        let points = history.compactMap { p in HealthspanSection.date(p.day).map { TrendPoint(date: $0, value: p.advance) } }
        let values = history.map(\.advance) + [0]
        let lo = (values.min() ?? 0).rounded(.down) - 1, hi = (values.max() ?? 0).rounded(.up) + 1
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Over time").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            TrendChart(points: points, gradient: Gradient(colors: [StrandPalette.agelessYoung, StrandPalette.agelessYoungDeep]),
                       valueRange: lo...hi, showsArea: false, baselineValue: 0, height: 160,
                       valueFormat: { HealthspanSection.signedNumber($0) },
                       accessibilityLabel: String(localized: "Rhythm age by day, in years older or younger than you; dashed line is your actual age"),
                       yDomain: lo...hi)
            Text("Years older (above zero) or younger (below zero) than you")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .agelessCard()
    }
}

// MARK: - About

/// What the rhythm age is, in AgeLess's About shape: a drawn motif, the short story, how it differs from AgeLess,
/// the study (linked), and the calculation folded away.
struct RhythmAgeAboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    private static let paper = URL(string: "https://doi.org/10.1038/s41746-024-01111-x")!
    /// Cited as published, never translated.
    private static let citation = "Shim, Fleisch & Barata, npj Digital Medicine 2024"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space5) {
                    RhythmIllustration()
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .background(StrandPalette.surfaceRaised.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("Daily rhythm").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                        Text("How young does your daily rhythm keep you?")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                    }
                    Text("Your strap feels every move you make. Over a week that shows how much you move, how clearly your days stand out from your nights and when you are most active. A large study turned exactly this rhythm into an age.")
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    section("Small changes count",
                            "Getting up for a few minutes every hour already shows in your rhythm.")
                    twoViews
                    section("Why the two can differ",
                            "AgeLess counts your steps. The rhythm age also sees the hours between your walks. If you walk a lot but sit for long stretches in between, AgeLess rates you well and the rhythm age less so.")
                    science
                    method
                    Text("Beta. Not a medical value.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(StrandPalette.agelessYoungDeep)
        #if os(macOS)
        .frame(minWidth: NoopMetrics.detailSheetMinWidth, minHeight: NoopMetrics.detailSheetMinHeight)
        #endif
    }

    private func section(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(text).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// AgeLess and the rhythm age side by side: two questions, two kinds of evidence.
    private var twoViews: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Two views of your age").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            viewRow(icon: "hourglass", title: "AgeLess",
                    text: "Adds up nine habits, from sleep to fitness, each measured against its own large study. Shows which habit helps you most.")
            Divider().overlay(StrandPalette.hairline)
            viewRow(icon: "sun.and.horizon", title: "Rhythm age",
                    text: "One model, built from the movement of 53,218 people and tested as a whole. Looks only at how your day moves and needs nothing but your strap.")
        }
        .agelessCard()
    }

    private func viewRow(icon: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                .frame(width: 32, height: 32)
                .background(StrandPalette.agelessYoung.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(title).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var science: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            section("Built on science",
                    "Built from a week of wrist movement of 53,218 people aged 40 to 69 in the UK Biobank, then tested on further people in the UK and the US. Tap to read the study.")
            Link(destination: Self.paper) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rhythm age").font(StrandFont.subhead.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
                        Text(verbatim: Self.citation)
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .agelessCard()
    }

    private var method: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("NOOP draws a smooth 24-hour curve through every minute of the last seven days. Its average height is your movement over the day and its swing the difference between day and night. The study's model turns these, the time the curve peaks and your age into years.")
                Text("Your strap measures movement its own way. NOOP translates it into the study's measure with a table built from one person's week of raw strap data, so for very active people the result may come out too low.")
                Text("It needs three days of wear, day and night, without the same hours missing every day. NOOP calculates it once a day on your device. Below age 40 it is a rough guide.")
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.top, NoopMetrics.space2)
        } label: {
            Text("How it's calculated").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
        }
        .agelessCard()
    }
}

/// The About motif: a day drawn as a wave that sets with the moon, rises with the sun and sinks again, over a
/// horizon line. AgeLess's cyan to indigo with a warm sun. Draws itself in once; Reduce Motion shows it whole.
struct RhythmIllustration: View {
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                RadialGradient(colors: [StrandPalette.agelessOld.opacity(0.22), .clear],
                               center: UnitPoint(x: 0.5, y: 0.3), startRadius: 4, endRadius: w * 0.35)
                RadialGradient(colors: [StrandPalette.agelessYoungDeep.opacity(0.22), .clear],
                               center: UnitPoint(x: 0.12, y: 0.75), startRadius: 2, endRadius: w * 0.3)
                // Horizon.
                Path { p in p.move(to: CGPoint(x: w * 0.06, y: h * 0.62)); p.addLine(to: CGPoint(x: w * 0.94, y: h * 0.62)) }
                    .stroke(StrandPalette.textTertiary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                // The day's wave: night low, day high.
                RhythmWave()
                    .trim(from: 0, to: drawn)
                    .stroke(LinearGradient(colors: [StrandPalette.agelessYoungDeep, StrandPalette.agelessYoung,
                                                    StrandPalette.agelessYoungDeep],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: StrandPalette.agelessYoung.opacity(0.6), radius: 8)
                // Sun at the day's top, moons in the troughs.
                Circle()
                    .fill(StrandPalette.agelessOld)
                    .frame(width: h * 0.13, height: h * 0.13)
                    .shadow(color: StrandPalette.agelessOld.opacity(0.8), radius: 10)
                    .position(x: w * 0.5, y: h * 0.12)
                    .opacity(drawn > 0.5 ? 1 : 0)
                ForEach([0.12, 0.88], id: \.self) { x in
                    Image(systemName: "moon.fill")
                        .font(.system(size: h * 0.1))
                        .foregroundStyle(StrandPalette.agelessYoungDeep.opacity(0.85))
                        .position(x: w * x, y: h * 0.9)
                        .opacity(Double(drawn))
                }
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion { drawn = 1 } else { withAnimation(.easeInOut(duration: 1.6)) { drawn = 1 } }
        }
    }
}

/// One day as a cosine: low at both ends (night), high in the middle (day).
struct RhythmWave: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 0...120 {
            let t = Double(i) / 120
            let y = 0.5 + 0.32 * cos(2 * Double.pi * (t - 0.5))
            let q = CGPoint(x: r.minX + r.width * (0.06 + 0.88 * t), y: r.minY + r.height * (1 - y) - r.height * 0.06)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }
}

// MARK: - More › Health & Body

/// AgeLess as its own screen under More › Health & Body: the same section the Health screen shows.
struct AgeLessScreen: View {
    var body: some View {
        ScreenScaffold(title: "AgeLess", subtitle: nil) {
            HealthspanSection()
        }
    }
}
