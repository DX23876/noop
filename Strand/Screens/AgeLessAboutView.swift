import SwiftUI
import StrandDesign
import StrandAnalytics

// AgeLessAboutView.swift — fork feature "AgeLess": what AgeLess is, in plain words, the studies it rests on
// (linked), and the calculation one level down for whoever wants it. Opened from the info button on the
// AgeLess screen.

/// The sheet: a drawn health motif, the short story, the science with its studies, then the method folded away.
struct AgeLessAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Each measure with the study behind it. Citations stay as published; the measure names are the app's.
    private static let studies: [(component: HealthspanEngine.Component, citation: String, doi: String)] = [
        (.sleepConsistency, "Windred et al., Sleep 2024", "10.1093/sleep/zsad253"),
        (.sleepDuration, "Saint-Maurice et al., Sleep 2024", "10.1093/sleep/zsad312"),
        (.dailySteps, "Paluch et al., Lancet Public Health 2022", "10.1016/S2468-2667(21)00302-9"),
        (.zone13, "Lee et al., Circulation 2022", "10.1161/CIRCULATIONAHA.121.058162"),
        (.zone45, "Ahmadi et al., Eur Heart J 2022", "10.1093/eurheartj/ehac572"),
        (.strength, "Momma et al., Br J Sports Med 2022", "10.1136/bjsports-2021-105061"),
        (.vo2max, "Kodama et al., JAMA 2009", "10.1001/jama.2009.681"),
        (.restingHR, "Zhang et al., CMAJ 2016", "10.1503/cmaj.150535"),
        (.leanMass, "Jayedi et al., Int J Obes 2022", "10.1038/s41366-022-01165-5"),
    ]
    private static let whitePaper = URL(string: "https://www.whoop.com/us/en/thelocker/Healthspan-Data-Meets-Longevity/")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space5) {
                    AgeLessIllustration()
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .background(StrandPalette.surfaceRaised.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("AgeLess")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("How young does your everyday life keep you?")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                    }
                    Text("AgeLess shows how old your body seems, measured by sleep, movement and fitness. Sleep well, move a lot, stay fit, and the number gets younger.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                    section("Getting younger is possible",
                            "Small steps count. AgeLess shows you which one helps you most.")
                    section("Your pace", "Aging speed shows where your last month is taking you.")
                    science
                    method
                    Text("Not a medical value. AgeLess is not affiliated with or endorsed by WHOOP.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
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

    private var science: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            section("Built on science",
                    "Each of the nine measures is linked to a long, healthy life in large studies with tens of thousands of people. Tap a study to read it.")
            ForEach(Self.studies, id: \.doi) { study in
                Link(destination: URL(string: "https://doi.org/" + study.doi)!) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(HealthspanSection.componentName(study.component))
                                .font(StrandFont.subhead.weight(.medium))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(verbatim: study.citation)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.agelessYoungDeep.legibleText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Link(destination: Self.whitePaper) {
                Label("Method: WHOOP Healthspan white paper (2025)", systemImage: "doc.text")
                    .font(StrandFont.subhead)
            }
        }
        .agelessCard()
    }

    private var method: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Nine measures of sleep, activity and fitness over the last six months, each compared with a recommendation for good long-term health. Large studies link every measure to all-cause mortality; the difference in risk is turned into years. Meeting every recommendation reads exactly at your age.")
                Text("Moderate activity counts minutes in workouts at 40 to 80 % of your heart-rate reserve, vigorous activity above 80 %. The reserve runs from your average sleeping heart rate to your maximum heart rate.")
                Text("Aging speed assumes your last 30 days continue for six months: 1.0× ages with the calendar, below 1.0× slower, below 0 you get younger.")
                Text("The method follows WHOOP's published Healthspan white paper (2025) and the studies it cites, computed on your device. It is an estimate to motivate healthy habits, not a medical or biological age and not a prediction of lifespan.")
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.top, NoopMetrics.space2)
        } label: {
            Text("How it's calculated")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .agelessCard()
    }
}

/// The header motif: a heartbeat line that rises out of a calm night (the moon), beats once and grows into a
/// leaf — sleep, heart and movement as one living line, in AgeLess's cyan to indigo with a warm spark. It
/// draws itself in once; Reduce Motion shows it whole.
struct AgeLessIllustration: View {
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let gradient = LinearGradient(colors: [StrandPalette.agelessYoungDeep, StrandPalette.agelessYoung],
                                          startPoint: .leading, endPoint: .trailing)
            ZStack {
                RadialGradient(colors: [StrandPalette.agelessYoung.opacity(0.28), .clear],
                               center: UnitPoint(x: 0.62, y: 0.55), startRadius: 4, endRadius: w * 0.45)
                RadialGradient(colors: [StrandPalette.agelessYoungDeep.opacity(0.22), .clear],
                               center: UnitPoint(x: 0.18, y: 0.35), startRadius: 2, endRadius: w * 0.3)
                // The moon: night and sleep.
                Circle()
                    .fill(StrandPalette.agelessYoungDeep.opacity(0.85))
                    .mask {
                        ZStack {
                            Circle()
                            Circle().scaleEffect(0.9).offset(x: h * 0.07, y: -h * 0.04).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .frame(width: h * 0.22, height: h * 0.22)
                    .position(x: w * 0.14, y: h * 0.26)
                    .opacity(Double(min(1, drawn * 3)))
                // The line: rest, one heartbeat, then up into a leaf.
                AgeLessHeartbeatLeaf()
                    .trim(from: 0, to: drawn)
                    .stroke(gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: StrandPalette.agelessYoung.opacity(0.6), radius: 8)
                // The warm spark where the heart beats.
                Circle()
                    .fill(StrandPalette.agelessOld)
                    .frame(width: 9, height: 9)
                    .shadow(color: StrandPalette.agelessOld.opacity(0.8), radius: 6)
                    .position(x: w * 0.42, y: h * 0.22)
                    .opacity(drawn > 0.45 ? 1 : 0)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion { drawn = 1 } else { withAnimation(.easeInOut(duration: 1.6)) { drawn = 1 } }
        }
    }
}

/// The heartbeat-into-leaf path, in a box it is stretched to.
struct AgeLessHeartbeatLeaf: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.04, 0.72))
        path.addLine(to: p(0.30, 0.72))
        path.addLine(to: p(0.35, 0.62))
        path.addLine(to: p(0.39, 0.86))
        path.addLine(to: p(0.42, 0.22))
        path.addLine(to: p(0.46, 0.80))
        path.addLine(to: p(0.50, 0.72))
        path.addCurve(to: p(0.70, 0.62), control1: p(0.58, 0.72), control2: p(0.64, 0.70))
        // The leaf: out along one edge to its tip, back along the other, then the midrib.
        path.addCurve(to: p(0.94, 0.18), control1: p(0.74, 0.30), control2: p(0.86, 0.18))
        path.addCurve(to: p(0.70, 0.62), control1: p(0.96, 0.40), control2: p(0.86, 0.62))
        path.addLine(to: p(0.86, 0.34))
        return path
    }
}
