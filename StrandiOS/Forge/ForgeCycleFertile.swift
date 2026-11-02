#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// How the likely fertile days are worked out, with the wearer's own numbers (prototype board
/// "CycleFertileInfo"). A rough estimate from past temperature rises or a logged ovulation test; never
/// contraception, and the page says so before anything else can be read as advice.
struct ForgeCycleFertileInfo: View {
    let snap: ForgeCycleSnapshot
    var onLog: () -> Void = {}
    @State private var scrolledPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: nil, title: String(localized: "Fertile days"), scrolledPast: $scrolledPast)
                warning
                steps
                if let f = snap.fertile, !f.pastRiseDays.isEmpty {
                    ForgeSectionTitle(title: "Your last cycles")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(f.pastRiseDays.enumerated()), id: \.offset) { i, day in
                            HStack {
                                Text(i == 0 ? String(localized: "Last cycle") : String(localized: "\(i + 1) cycles ago"))
                                    .foregroundStyle(ForgeColor.secondary)
                                Spacer()
                                Text("rise on day \(day)").foregroundStyle(ForgeColor.text)
                            }
                            .font(ForgeFont.body)
                        }
                        Text("The wider your rises spread, the wider the window NOOP shows.")
                            .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    .forgeCard(radius: 22, padding: 16)
                }
                Button(action: onLog) {
                    ForgeRow(systemImage: "testtube.2", tint: ForgeColor.cycleFertile, title: String(localized: "Log an ovulation test"),
                             subtitle: String(localized: "A positive test narrows the window to about two days"))
                        .forgeCard(radius: 22, padding: 0)
                }
                .buttonStyle(.plain)
                Text("Shown only after 3 cycles with a clear temperature rise, or once you log a positive test. You can hide fertile days in the cycle settings.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .health))
        .forgeDetailBar(title: String(localized: "Fertile days"), showsTitle: scrolledPast)
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ForgeColor.effort).accessibilityHidden(true)
            (Text("Not birth control. ").bold()
             + Text("This is a rough estimate from a wrist sensor, not a medical device. Cycles shift with stress, illness, travel and sleep. Do not use it on its own to avoid or plan a pregnancy."))
                .font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .forgeCard(radius: 22, padding: 16)
    }

    private var steps: some View {
        let f = snap.fertile
        let range = f.flatMap { e -> (Int, Int)? in
            guard let lo = e.pastRiseDays.min(), let hi = e.pastRiseDays.max() else { return nil }
            return (lo, hi)
        }
        return VStack(alignment: .leading, spacing: 14) {
            Text("How NOOP estimates your fertile days").font(.system(.headline)).foregroundStyle(ForgeColor.text)
            step(1, String(localized: "Your temperature rises a day or two after ovulation."),
                 range.map { r in
                     String(localized: "In your last \(f?.pastRiseDays.count ?? 0) cycles it rose between day \(r.0) and day \(r.1).")
                 })
            step(2, String(localized: "Sperm can live up to five days, so the likely fertile days run from five days before ovulation to the day of it."),
                 f.map { String(localized: "For you this cycle: about day \($0.firstDay) to \($0.lastDay).") })
            step(3, String(localized: "Once your nights show the rise, the window closes for this cycle."),
                 f?.basis == .ovulationTest ? String(localized: "This cycle uses your positive ovulation test.") : nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .forgeCard(radius: 22, padding: 16)
    }

    private func step(_ n: Int, _ text: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(.footnote, weight: .bold)).foregroundStyle(ForgeColor.text)
                .frame(width: 26, height: 26).background(Circle().fill(ForgeColor.fill))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                if let detail { Text(detail).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The cycle at a glance for the Health and Today tabs (prototype boards "CycleHealthTab" and
/// "CycleTodayCard"): the cycle day, a row of days around today, one line on the fertile days or the phase,
/// and the three ways to log. Shown only while cycle tracking is on; a tap opens the cycle page.
struct ForgeCycleSummaryCard: View {
    var showsLogButtons = true
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var appModel: AppModel
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    @AppStorage(ForgeCycleSnapshot.fertileKey) private var showFertile = true
    @StateObject private var loader = ForgeCycleLoader()
    @State private var logging = false

    var body: some View {
        // Loaded from the body, not a `.task`: with nothing to show yet the view has no children, and SwiftUI
        // never runs a task attached to an empty group (the same reason `PeriodStartsLoader` exists).
        let _ = loader.request(seq: cycleEnabled ? repo.cycleTrackingSeq * 1_000_003 + repo.refreshSeq : -1,
                                repo: repo, model: appModel, enabled: cycleEnabled)
        Group {
            if cycleEnabled, !loader.starts.isEmpty {
                let snap = ForgeCycleSnapshot.make(result: appModel.cyclePhase, starts: loader.starts, log: loader.log, days: repo.days,
                                                   today: Date(), showFertile: showFertile)
                card(snap)
            }
        }
        .sheet(isPresented: $logging) {
            ForgeCycleLogSheet(day: Repository.localDayKey(Date()), existing: loader.log[Repository.localDayKey(Date())] ?? CycleLog.Day(),
                               starts: loader.starts) { await appModel.refreshV5Signals() }
        }
    }

    private func card(_ snap: ForgeCycleSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: ForgeRoute.cycle) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Cycle · \(snap.cycleDayText)").font(.system(.headline)).foregroundStyle(ForgeColor.text)
                        Spacer(minLength: 8)
                        if let phase = snap.phase {
                            Text(phase.title).font(.system(.footnote, weight: .semibold)).foregroundStyle(phase.color)
                        }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ForgeColor.tertiary)
                    }
                    strip(snap)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.fertileLine?.title ?? snap.phase?.title ?? String(localized: "No clear pattern yet"))
                            .font(.system(.callout, weight: .semibold)).foregroundStyle(ForgeColor.text)
                        if let sub = subline(snap) {
                            Text(sub).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsLogButtons {
                HStack(spacing: 8) {
                    logChip(String(localized: "cycle.period", defaultValue: "Period"), "drop.fill", ForgeColor.cyclePeriod)
                    logChip(String(localized: "Symptoms"), "cross.case.fill", ForgeColor.effort)
                    logChip(String(localized: "Mood"), "face.smiling", ForgeColor.rest)
                }
            }
        }
        .forgeCard(radius: 22, padding: 14)
    }

    private func subline(_ snap: ForgeCycleSnapshot) -> String? {
        var parts: [String] = []
        if case .during? = snap.fertileStatus, let detail = snap.fertileLine?.detail { parts.append(detail.prefix(1).uppercased() + String(detail.dropFirst()) + ".") }
        if let next = snap.nextLine { parts.append(next + ".") }
        if snap.fertile != nil { parts.append(String(localized: "Rough estimate, not birth control.")) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Nine days around today, today large and ringed, the likely fertile days green.
    private func strip(_ snap: ForgeCycleSnapshot) -> some View {
        HStack {
            ForEach(-4...4, id: \.self) { offset in
                let d = (snap.todayOnWheel ?? 1) + offset
                let fertile = snap.isFertile(day: d)
                let colour = fertile ? ForgeColor.cycleFertile : (d >= 1 ? (snap.phase(onDay: d)?.color ?? ForgeColor.tertiary) : ForgeColor.tertiary)
                Circle()
                    .fill(colour.opacity(offset <= 0 || fertile ? 1 : 0.35))
                    .frame(width: offset == 0 ? 18 : 12, height: offset == 0 ? 18 : 12)
                    .overlay {
                        if offset == 0 { Circle().strokeBorder(ForgeColor.text, lineWidth: 2).padding(-5) }
                    }
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
    }

    private func logChip(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        Button { logging = true } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(ForgeColor.text)
            }
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(ForgeColor.fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Log \(title)"))
    }
}
/// Loads the logged starts and days for `ForgeCycleSummaryCard` outside the view tree; starts a read only
/// when the cycle-tracking seq changed and publishes from the task, never during a view update.
@MainActor
final class ForgeCycleLoader: ObservableObject {
    @Published private(set) var starts: [String] = []
    @Published private(set) var log: [String: CycleLog.Day] = [:]
    private var lastSeq: Int?
    private var load: Task<Void, Never>?

    func request(seq: Int, repo: Repository, model: AppModel, enabled: Bool) {
        guard seq != lastSeq else { return }
        lastSeq = seq
        load?.cancel()
        guard enabled else { return }
        load = Task { [weak self] in
            let today = Date()
            let starts = await repo.periodStarts()
            let log = await repo.cycleLog(from: Repository.localDayKey(today.addingTimeInterval(-180 * 86_400)),
                                          to: Repository.localDayKey(today))
            if model.cyclePhase == nil { await model.refreshV5Signals() }
            guard !Task.isCancelled, let self else { return }
            self.starts = starts
            self.log = log
        }
    }
}
#endif
