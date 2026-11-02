#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The rest of one night on the redesign's Sleep tab (prototype board "SleepNight"): the stages against the
/// wearer's typical night, what shaped the night against the usual, the sleep-debt ledger and the body
/// clock. Every value is the shipped `SleepModel`'s; the ledger and the clock dial are the shipped cards.
struct ForgeNightBreakdown: View {
    let model: SleepModel
    let night: Night
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stages
            shaped
            ForgeSectionTitle(title: "Sleep debt")
            SleepDebtLedgerCard(model: model)
                .forgeCard(radius: 22, padding: 14)
            if let phase = appModel.circadianPhase, phase.confidence != .unreadable {
                ForgeSectionTitle(title: "Body clock")
                BodyClockDialCard(estimate: phase,
                                  actualBedHour: SleepView.localClockHour(night.session.effectiveStartTs),
                                  actualWakeHour: SleepView.localClockHour(night.session.endTs))
                    .forgeCard(radius: 22, padding: 14)
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
            ForgeSectionTitle(title: "Stages")
            VStack(spacing: 10) {
                ForEach(rows, id: \.name) { r in stageRow(r, top: top) }
                Text("The mark is your typical night from the last 30.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .forgeCard(radius: 22, padding: 14)
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
        let rows: [(String, SleepModel.Metric, String, Bool)] = [
            (String(localized: "Hours against need"), model.hoursVsNeeded, "%", true),
            (String(localized: "Efficiency"), model.efficiency, "%", true),
            (String(localized: "Steadiness"), model.consistency, "%", true),
            (String(localized: "Restorative sleep"), model.restorative, "%", true),
            (String(localized: "Breathing rate"), model.respiratory, String(localized: "/min"), false),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            ForgeSectionTitle(title: "What shaped the night")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Rectangle().fill(ForgeColor.separator).frame(height: 0.5) }
                    shapedRow(r.0, r.1, unit: r.2, higherIsBetter: r.3)
                }
            }
            .forgeCard(radius: 22, padding: 14)
        }
    }

    private func shapedRow(_ label: String, _ m: SleepModel.Metric, unit: String, higherIsBetter: Bool) -> some View {
        let value = m.latest.map { "\(Int($0.rounded()))\(unit == "%" ? " %" : " " + unit)" } ?? "–"
        let usual = m.typical.map { String(localized: "usual \(Int($0.rounded()))") }
        let delta: Int = {
            guard let v = m.latest, let t = m.typical, higherIsBetter else { return 0 }
            let d = v - t
            return abs(d) < 2 ? 0 : (d > 0 ? 1 : -1)
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(.subheadline, weight: .semibold)).foregroundStyle(ForgeColor.text)
                if let usual { Text(usual).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary) }
            }
            Spacer(minLength: 8)
            Text(value).font(ForgeFont.rounded(17, .semibold)).foregroundStyle(ForgeColor.text)
            if higherIsBetter { ForgeDirection(delta: delta) }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
#endif
