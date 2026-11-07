#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The rest of one night on the redesign's Sleep tab (prototype board "SleepNight"): the stages against the
/// wearer's typical night, what shaped the night against the usual, the sleep-debt ledger and the body
/// clock. Every value is the shipped `SleepModel`'s; the ledger and the clock dial are the shipped cards.
struct ForgeNightBreakdown: View {
    let model: SleepModel
    let night: Night
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var repo: Repository

    /// The wake day's stored row: the figures below belong to the night on screen, not to the newest one.
    private var wakeKey: String { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs))) }
    private var row: DailyMetric? { repo.days.last { $0.day == wakeKey } }

    /// Share of the time in bed spent asleep, from the night's own stages.
    static func efficiency(_ night: Night) -> Double? {
        night.stages.total > 0 ? night.stages.asleep / night.stages.total * 100 : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stages
            shaped
            ForgeSectionTitle(title: "Sleep debt")
            SleepDebtLedgerCard(model: model)
                .forgeCard(radius: ForgeRadius.card, padding: 14)
            if let phase = appModel.circadianPhase, phase.confidence != .unreadable {
                ForgeSectionTitle(title: "Body clock")
                BodyClockDialCard(estimate: phase,
                                  actualBedHour: SleepView.localClockHour(night.session.effectiveStartTs),
                                  actualWakeHour: SleepView.localClockHour(night.session.endTs))
                    .forgeCard(radius: ForgeRadius.card, padding: 14)
            }
        }
    }

    // MARK: Stages against the typical night

    private struct StageRow {
        let name: String
        let minutes: Double
        let typical: Double?
        let color: Color
    }

    private var stages: some View {
        let s = night.stages
        let rows = [
            StageRow(name: String(localized: "Deep"), minutes: s.deep, typical: model.typicalDeepMin, color: StrandPalette.sleepStageColor(.deep)),
            StageRow(name: String(localized: "REM"), minutes: s.rem, typical: model.typicalRemMin, color: StrandPalette.sleepStageColor(.rem)),
            StageRow(name: String(localized: "Light"), minutes: s.light, typical: model.typicalLightMin, color: StrandPalette.sleepStageColor(.light)),
            StageRow(name: String(localized: "Awake"), minutes: s.awake, typical: nil, color: StrandPalette.sleepStageColor(.awake)),
        ]
        let top = max(rows.map { max($0.minutes, $0.typical ?? 0) }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForgeSectionTitle(title: "Stages")
                Spacer()
                ExplainerInfoButton(
                    title: String(localized: "How a night runs"),
                    text: String(localized: "Sleep moves through cycles of about 90 minutes. Deep sleep comes mostly early in the night, REM mostly towards morning, and short wakings are normal. Your own night can look different.")) {
                        ExplainerNightStages()
                    }
                    .padding(.vertical, -12)
            }
            VStack(spacing: 10) {
                ForEach(rows, id: \.name) { r in stageRow(r, top: top) }
                Text("The mark is your typical night from the last 30.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .forgeCard(radius: ForgeRadius.card, padding: 14)
        }
    }

    private func stageRow(_ r: StageRow, top: Double) -> some View {
        let spoken = r.typical.map { String(localized: "\(Self.duration(r.minutes)), typical \(Self.duration($0))") } ?? Self.duration(r.minutes)
        return HStack(spacing: 10) {
            Text(r.name).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                .frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ForgeColor.fill)
                    Capsule().fill(r.color).frame(width: max(4, geo.size.width * r.minutes / top))
                    if let typical = r.typical {
                        // The wearer's typical amount, as a mark across the bar.
                        RoundedRectangle(cornerRadius: 1).fill(ForgeColor.text.opacity(0.6))
                            .frame(width: 2, height: 18)
                            .offset(x: geo.size.width * typical / top - 1)
                    }
                }
            }
            .frame(height: 12)
            Text(Self.duration(r.minutes)).font(ForgeFont.rounded(15, .semibold)).foregroundStyle(ForgeColor.text)
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(r.name))
        .accessibilityValue(Text(spoken))
    }

    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return "\(m / 60):\(String(format: "%02d", m % 60))"
    }

    // MARK: What shaped the night

    private var shaped: some View {
        let stages = night.stages
        let upToNight = repo.days.filter { $0.day <= wakeKey }
        let need = repo.importedSleep[wakeKey]?.needMin ?? SleepModel.debtNeedMin(days: repo.days)
        let bedtimes = repo.sleeps.filter { $0.endTs <= night.session.endTs }
        let candidates: [(String, Double?, Double?, String, Bool)] = [
            (String(localized: "Hours against need"), need > 0 && stages.asleep > 0 ? stages.asleep / need * 100 : nil,
             model.hoursVsNeeded.typical, "%", true),
            (String(localized: "Efficiency"), Self.efficiency(night), model.efficiency.typical, "%", true),
            (String(localized: "Steadiness"),
             SleepModel.consistencySeries(days: upToNight, sleeps: bedtimes, importedSleep: repo.importedSleep).series.last,
             model.consistency.typical, "%", true),
            (String(localized: "Restorative sleep"), stages.asleep > 0 ? (stages.deep + stages.rem) / stages.asleep * 100 : nil,
             model.restorative.typical, "%", true),
            (String(localized: "Breathing rate"), row?.respRateBpm, model.respiratory.typical, String(localized: "/min"), false),
        ]
        // A figure this night does not have is left out, not drawn as a dash. So is one that has never left
        // zero (tonight 0, usual 0): that is a measure without enough nights yet, not a result.
        let rows = candidates.filter { $0.1 != nil && !($0.1 == 0 && ($0.2 ?? 0) == 0) }
        // The three shares of the night lead as rings; the rest follow as rows with the usual marked.
        let ringNames: Set<String> = [String(localized: "Hours against need"), String(localized: "Efficiency"),
                                      String(localized: "Restorative sleep")]
        let rings = rows.filter { ringNames.contains($0.0) }
        let rest = rows.filter { !ringNames.contains($0.0) }
        return VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "What shaped the night")
            VStack(spacing: 12) {
                if !rings.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(rings.enumerated()), id: \.offset) { i, r in
                            ForgeShareRing(label: r.0, value: r.1 ?? 0, typical: r.2, index: i)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 4)
                }
                if !rings.isEmpty && !rest.isEmpty { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                ForEach(Array(rest.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                    shapedRow(r.0, value: r.1, typical: r.2, unit: r.3, higherIsBetter: r.4)
                }
            }
            .forgeCard(radius: ForgeRadius.card, padding: 14)
        }
    }

    private func shapedRow(_ label: String, value number: Double?, typical: Double?, unit: String, higherIsBetter: Bool) -> some View {
        let value = number.map { "\(Int($0.rounded()))\(unit == "%" ? " %" : " " + unit)" } ?? "–"
        let usual = typical.map { String(localized: "usual \(Int($0.rounded()))") }
        let delta: Int = {
            guard let v = number, let t = typical, higherIsBetter else { return 0 }
            let d = v - t
            return abs(d) < 2 ? 0 : (d > 0 ? 1 : -1)
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    if let usual { Text(usual).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary) }
                }
                Spacer(minLength: 8)
                Text(value).font(ForgeFont.rounded(20, .bold)).foregroundStyle(ForgeColor.text)
                    .contentTransition(.numericText())
                if higherIsBetter { ForgeDirection(delta: delta) }
            }
            // A share of the night as a bar, with the wearer's usual as a mark across it.
            if unit == "%", let number {
                ForgeShareBar(fraction: number / 100, typical: typical.map { $0 / 100 })
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// One share of the night as a ring: tonight's figure in the middle, the usual as a tick on the track.
/// The ring draws in once, a few hundredths after its neighbour; with Reduce Motion it is simply there.
struct ForgeShareRing: View {
    let label: String
    let value: Double
    let typical: Double?
    var index = 0
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { min(max(value / 100, 0), 1) }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.activeLocale))
    }
    private var below: Bool { typical.map { value < $0 - 2 } ?? false }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(ForgeColor.rest.opacity(0.16), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: drawn ? fraction : 0)
                    .stroke(AngularGradient(colors: [ForgeColor.rest.opacity(0.65), ForgeColor.rest],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.01))),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let typical {
                    // The usual, as a short tick across the track.
                    Capsule().fill(ForgeColor.text.opacity(0.7))
                        .frame(width: 2.5, height: 15)
                        .offset(y: -37)
                        .rotationEffect(.degrees(360 * min(max(typical / 100, 0), 1)))
                }
                VStack(spacing: 0) {
                    Text("\(Int(value.rounded()))")
                        .font(ForgeFont.rounded(22, .bold)).foregroundStyle(ForgeColor.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(verbatim: "%").font(.system(.caption2, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                }
            }
            .frame(width: 74, height: 74)
            Text(label).font(.system(.caption, weight: .semibold)).foregroundStyle(ForgeColor.text)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            if let typical {
                Text("usual \(Int(typical.rounded()))").font(.system(.caption2))
                    .foregroundStyle(below ? ForgeColor.effortInk : ForgeColor.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(typical.map { Text(Self.percent(value)) + Text(verbatim: ", ") + Text("usual \(Int($0.rounded()))") }
                            ?? Text(Self.percent(value)))
        .onAppear {
            if reduceMotion { drawn = true; return }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.9).delay(0.08 * Double(index))) { drawn = true }
        }
    }
}

/// A share as a thin bar with the usual marked across it.
struct ForgeShareBar: View {
    let fraction: Double
    let typical: Double?
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ForgeColor.rest.opacity(0.16))
                Capsule().fill(LinearGradient(colors: [ForgeColor.rest.opacity(0.6), ForgeColor.rest],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1) * (drawn ? 1 : 0)))
                if let typical {
                    RoundedRectangle(cornerRadius: 1).fill(ForgeColor.text.opacity(0.65))
                        .frame(width: 2, height: 14)
                        .offset(x: geo.size.width * min(max(typical, 0), 1) - 1)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion { drawn = true; return }
            withAnimation(.spring(response: 0.8, dampingFraction: 0.9)) { drawn = true }
        }
    }
}
#endif
