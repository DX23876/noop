import SwiftUI
import StrandDesign

// Pictures that explain a figure, opened from its info symbol or set beside its explanation. Each is drawn
// here rather than shipped as an image, so it follows light, dark and the colour profile, and its few words
// are translated with the app. They illustrate how a measure works; none shows the wearer's own data.

/// The soft tinted panel every explaining picture sits on. Hidden from VoiceOver, the text beside it says
/// the same.
struct ExplainerPanel<Content: View>: View {
    let tint: Color
    var height: CGFloat = 176
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.05)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .accessibilityHidden(true)
    }
}

/// A picture with its title and short text, as a sheet.
struct ExplainerSheet<Picture: View>: View {
    let title: String
    let text: String
    @ViewBuilder var picture: () -> Picture
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    picture()
                    Text(title)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(text)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The info symbol that opens a picture.
struct ExplainerInfoButton<Picture: View>: View {
    let title: String
    let text: String
    @ViewBuilder var picture: () -> Picture
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "info.circle")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("What this means"))
        .sheet(isPresented: $open) { ExplainerSheet(title: title, text: text, picture: picture) }
    }
}

// MARK: - Heartbeats

/// One heartbeat trace: a beat at each position along the width, the rest flat.
private struct BeatTrace: Shape {
    /// Where each beat's peak falls, 0 to 1 along the width.
    let beats: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY + rect.height * 0.22
        let tall = rect.height * 0.62
        let unit = rect.width * 0.018
        path.move(to: CGPoint(x: rect.minX, y: mid))
        for beat in beats {
            let x = rect.minX + beat * rect.width
            path.addLine(to: CGPoint(x: x - unit * 3.2, y: mid))
            path.addQuadCurve(to: CGPoint(x: x - unit * 1.4, y: mid),
                              control: CGPoint(x: x - unit * 2.3, y: mid - tall * 0.13))
            path.addLine(to: CGPoint(x: x - unit * 0.6, y: mid + tall * 0.12))
            path.addLine(to: CGPoint(x: x, y: mid - tall))
            path.addLine(to: CGPoint(x: x + unit * 0.7, y: mid + tall * 0.2))
            path.addLine(to: CGPoint(x: x + unit * 1.5, y: mid))
            path.addQuadCurve(to: CGPoint(x: x + unit * 4, y: mid),
                              control: CGPoint(x: x + unit * 2.8, y: mid - tall * 0.2))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: mid))
        return path
    }
}

/// The gaps between heartbeats are not equal, and that spread is what HRV measures.
struct ExplainerHeartbeats: View {
    private let beats: [CGFloat] = [0.1, 0.33, 0.6, 0.81]
    private let gaps = ["820 ms", "910 ms", "760 ms"]
    private var tint: Color { StrandPalette.chargeColor }

    var body: some View {
        ExplainerPanel(tint: tint) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    BeatTrace(beats: beats)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        .shadow(color: tint.opacity(0.45), radius: 5)
                        .frame(height: geo.size.height - 34)
                    ForEach(gaps.indices, id: \.self) { i in
                        let a = beats[i] * w
                        let b = beats[i + 1] * w
                        VStack(spacing: 3) {
                            Rectangle().fill(StrandPalette.textTertiary).frame(height: 1)
                                .overlay(alignment: .leading) { tick }
                                .overlay(alignment: .trailing) { tick }
                            Text(verbatim: gaps[i])
                                .font(StrandFont.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(width: b - a - 6)
                        .offset(x: a + 3, y: geo.size.height - 26)
                    }
                }
            }
        }
    }

    private var tick: some View {
        Rectangle().fill(StrandPalette.textTertiary).frame(width: 1, height: 7)
    }
}

/// A calm heart beside a tense one: slower with lively gaps, faster with even ones.
struct ExplainerStressHearts: View {
    private var calm: Color { StrandPalette.chargeColor }
    private var tense: Color { StrandPalette.effortColor }

    var body: some View {
        ExplainerPanel(tint: tense, height: 190) {
            VStack(alignment: .leading, spacing: 8) {
                lane(String(localized: "Calm"), calm, beats: [0.12, 0.36, 0.66, 0.9])
                lane(String(localized: "Tense"), tense, beats: [0.09, 0.25, 0.41, 0.57, 0.73, 0.89])
            }
        }
    }

    private func lane(_ name: String, _ tint: Color, beats: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
            BeatTrace(beats: beats)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: tint.opacity(0.4), radius: 4)
        }
    }
}

// MARK: - Scores

/// What flows into a score: its inputs on threads running into its ring.
struct ExplainerScoreInputs: View {
    let domain: DomainTheme
    let inputs: [String]

    var body: some View {
        let tint = domain.color
        ExplainerPanel(tint: tint) {
            GeometryReader { geo in
                let size = geo.size
                let ring = min(size.height * 0.74, 112)
                let center = CGPoint(x: size.width - ring / 2 - 4, y: size.height / 2)
                let startX = size.width * 0.46
                let rowHeight = size.height / CGFloat(max(inputs.count, 1))
                ZStack(alignment: .topLeading) {
                    Path { path in
                        for i in inputs.indices {
                            let y = rowHeight * (CGFloat(i) + 0.5)
                            path.move(to: CGPoint(x: startX, y: y))
                            path.addCurve(to: CGPoint(x: center.x - ring / 2 - 2, y: center.y),
                                          control1: CGPoint(x: startX + (center.x - startX) * 0.4, y: y),
                                          control2: CGPoint(x: startX + (center.x - startX) * 0.4, y: center.y))
                        }
                    }
                    .stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    Circle()
                        .stroke(tint.opacity(0.18), lineWidth: 9)
                        .frame(width: ring, height: ring)
                        .position(center)
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: tint.opacity(0.5), radius: 7)
                        .frame(width: ring, height: ring)
                        .position(center)
                    Text(verbatim: domain.productName)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: ring - 22)
                        .position(center)
                    ForEach(inputs.indices, id: \.self) { i in
                        Text(verbatim: inputs[i])
                            .font(StrandFont.footnote.weight(.medium))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(width: startX - 4, height: rowHeight, alignment: .leading)
                            .offset(y: rowHeight * CGFloat(i))
                    }
                }
            }
        }
    }

    static var charge: ExplainerScoreInputs {
        .init(domain: .charge, inputs: [String(localized: "HRV"), String(localized: "Resting heart rate"),
                                        String(localized: "Sleep"), String(localized: "Breathing"),
                                        String(localized: "Skin temperature")])
    }

    static var effort: ExplainerScoreInputs {
        .init(domain: .effort, inputs: [String(localized: "Heart rate"), String(localized: "Time"),
                                        String(localized: "Strength rating")])
    }

    static var rest: ExplainerScoreInputs {
        .init(domain: .rest, inputs: [String(localized: "How long"), String(localized: "How well"),
                                      String(localized: "How regular"), String(localized: "Deep and REM")])
    }
}

// MARK: - Training

/// Weeks of load against the wearer's usual band, the newest week picked out.
struct ExplainerLoadBand: View {
    let tint: Color
    private let weeks: [CGFloat] = [0.44, 0.52, 0.48, 0.6, 0.5, 0.56, 0.54, 0.74]
    private let band: ClosedRange<CGFloat> = 0.42...0.64

    var body: some View {
        ExplainerPanel(tint: tint) {
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: h * (1 - band.upperBound))
                        Rectangle().fill(tint.opacity(0.18))
                            .overlay(alignment: .topLeading) {
                                Text("Your usual")
                                    .font(StrandFont.caption.weight(.semibold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .padding(.horizontal, 6).padding(.top, 2)
                            }
                            .frame(height: h * (band.upperBound - band.lowerBound))
                        Color.clear.frame(height: h * band.lowerBound)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(weeks.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(i == weeks.count - 1 ? tint : tint.opacity(0.42))
                                .frame(height: h * weeks[i])
                                .shadow(color: i == weeks.count - 1 ? tint.opacity(0.5) : .clear, radius: 6)
                        }
                    }
                }
            }
        }
    }
}

/// A set counts for more the closer it comes to the point where no further repetition is possible.
struct ExplainerWeightedSets: View {
    private var tint: Color { StrandPalette.effortColor }
    private let heights: [CGFloat] = [0.2, 0.32, 0.48, 0.7, 1]

    var body: some View {
        ExplainerPanel(tint: tint) {
            VStack(spacing: 8) {
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(heights.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tint.opacity(0.28 + 0.18 * Double(i)))
                                .frame(height: geo.size.height * heights[i])
                                .shadow(color: i == heights.count - 1 ? tint.opacity(0.5) : .clear, radius: 7)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                HStack {
                    Text("Many left in the tank")
                    Spacer()
                    Text("None left")
                }
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }
}

// MARK: - Sleep

/// A typical night's stages: deep sleep mostly early, REM mostly towards morning.
struct ExplainerNightStages: View {
    private struct Block { let lane: Int; let length: CGFloat }
    private let blocks: [Block] = [
        .init(lane: 2, length: 0.05), .init(lane: 3, length: 0.13), .init(lane: 2, length: 0.05), .init(lane: 1, length: 0.03),
        .init(lane: 2, length: 0.07), .init(lane: 3, length: 0.1), .init(lane: 2, length: 0.06), .init(lane: 1, length: 0.06),
        .init(lane: 0, length: 0.012), .init(lane: 2, length: 0.09), .init(lane: 3, length: 0.03), .init(lane: 2, length: 0.07),
        .init(lane: 1, length: 0.1), .init(lane: 0, length: 0.012), .init(lane: 2, length: 0.05), .init(lane: 1, length: 0.086)
    ]

    private func color(_ lane: Int) -> Color {
        switch lane {
        case 0: return StrandPalette.sleepAwake
        case 1: return StrandPalette.sleepREM
        case 2: return StrandPalette.sleepLight
        default: return StrandPalette.sleepDeep
        }
    }

    var body: some View {
        ExplainerPanel(tint: StrandPalette.restColor, height: 190) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    laneName(String(localized: "Awake"))
                    laneName(String(localized: "REM"))
                    laneName(String(localized: "Light"))
                    laneName(String(localized: "Deep"))
                }
                GeometryReader { geo in
                    let laneHeight = geo.size.height / 4
                    let total = blocks.reduce(0) { $0 + $1.length }
                    let unit = geo.size.width / total
                    ForEach(blocks.indices, id: \.self) { i in
                        let x = blocks[..<i].reduce(0) { $0 + $1.length } * unit
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(color(blocks[i].lane))
                            .frame(width: max(blocks[i].length * unit - 1, 3), height: laneHeight - 10)
                            .offset(x: x, y: CGFloat(blocks[i].lane) * laneHeight + 5)
                    }
                }
            }
        }
    }

    private func laneName(_ name: String) -> some View {
        Text(verbatim: name)
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.75)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Body

/// Where the tape goes for the body-fat estimate. The hip belongs to one of the two formulas only.
struct ExplainerBodyTape: View {
    let showsHips: Bool
    private var tint: Color { StrandPalette.accent }

    var body: some View {
        ExplainerPanel(tint: tint, height: 210) {
            GeometryReader { geo in
                let h = geo.size.height
                ZStack {
                    Image(systemName: "figure.stand")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(height: h)
                    tape(String(localized: "Around the neck"), y: h * 0.2, width: geo.size.width, length: 18)
                    tape(String(localized: "Around the waist"), y: h * 0.43, width: geo.size.width, length: 40)
                    if showsHips {
                        tape(String(localized: "Around the hips"), y: h * 0.53, width: geo.size.width, length: 42)
                    }
                }
            }
        }
    }

    private func tape(_ name: String, y: CGFloat, width: CGFloat, length: CGFloat) -> some View {
        HStack(spacing: 0) {
            Capsule().fill(tint).frame(width: length, height: 3).shadow(color: tint.opacity(0.5), radius: 3)
            Rectangle().fill(tint.opacity(0.45)).frame(width: 52 - length / 2, height: 1)
            Text(verbatim: name)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.leading, 6)
        }
        .padding(.leading, width / 2 - length / 2)
        .frame(width: width, alignment: .leading)
        .position(x: width / 2, y: y)
    }
}

// MARK: - Breathing

/// The shape of a breath: a square with four equal sides, or a wave with one even swing.
struct ExplainerBreathShapes: View {
    private var tint: Color { StrandPalette.metricCyan }

    var body: some View {
        ExplainerPanel(tint: tint, height: 186) {
            HStack(spacing: 22) {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .shadow(color: tint.opacity(0.5), radius: 5)
                        .overlay {
                            ZStack {
                                Text("In").frame(maxHeight: .infinity, alignment: .top)
                                Text("Hold").frame(maxWidth: .infinity, alignment: .trailing)
                                Text("Out").frame(maxHeight: .infinity, alignment: .bottom)
                                Text("Hold").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(9)
                        }
                        .aspectRatio(1, contentMode: .fit)
                    Text(verbatim: "4 · 4 · 4 · 4 s").font(StrandFont.footnote.monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                }
                VStack(spacing: 8) {
                    GeometryReader { geo in
                        ExplainerWave()
                            .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .shadow(color: tint.opacity(0.5), radius: 5)
                        // The first rise and fall named; the wave repeats them.
                        Text("In")
                            .position(x: geo.size.width * 0.08, y: geo.size.height * 0.2)
                        Text("Out")
                            .position(x: geo.size.width * 0.42, y: geo.size.height * 0.2)
                    }
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(5.5, format: .number) · \(5.5, format: .number) s").font(StrandFont.footnote.monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}

private struct ExplainerWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY + 8
        let amp = rect.height * 0.3
        path.move(to: CGPoint(x: rect.minX, y: mid))
        let steps = 60
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: rect.minX + t * rect.width, y: mid - sin(t * .pi * 4) * amp))
        }
        return path
    }
}

// MARK: - Energy

/// The day's energy: what was burned, split in two, beside what was eaten.
struct ExplainerEnergyBars: View {
    private var resting: Color { StrandPalette.energyResting }
    private var activity: Color { StrandPalette.energyActive }
    private var eaten: Color { StrandPalette.textPrimary }

    var body: some View {
        ExplainerPanel(tint: StrandPalette.energyHighlight, height: 150) {
            VStack(alignment: .leading, spacing: 12) {
                row(String(localized: "Burned")) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            segment(String(localized: "Resting"), resting).frame(width: geo.size.width * 0.66)
                            segment(String(localized: "Active"), activity)
                        }
                    }
                }
                row(String(localized: "Eaten")) {
                    GeometryReader { geo in
                        Capsule().fill(eaten).frame(width: geo.size.width * 0.86)
                    }
                }
            }
        }
    }

    private func row<Bar: View>(_ name: String, @ViewBuilder bar: () -> Bar) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: name).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
            bar().frame(height: 26)
        }
    }

    private func segment(_ name: String, _ tint: Color) -> some View {
        Capsule().fill(tint)
            .overlay {
                Text(verbatim: name)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
            }
    }
}

// MARK: - ECG

/// Fingers of the free hand on the two indents of the strap's clasp.
struct ExplainerClaspFingers: View {
    private var tint: Color { StrandPalette.accent }

    var body: some View {
        ExplainerPanel(tint: tint, height: 170) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let bandY = h * 0.68
                ZStack {
                    Capsule().fill(StrandPalette.textTertiary.opacity(0.4))
                        .frame(width: w, height: 44)
                        .position(x: w / 2, y: bandY)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(StrandPalette.textSecondary.opacity(0.75))
                        .frame(width: 112, height: 58)
                        .position(x: w / 2, y: bandY)
                    ForEach([-1, 1], id: \.self) { side in
                        let x = w / 2 + CGFloat(side) * 28
                        Circle().fill(tint).frame(width: 18, height: 18)
                            .shadow(color: tint.opacity(0.7), radius: 6)
                            .position(x: x, y: bandY)
                        Capsule().fill(tint.opacity(0.32))
                            .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 1.5))
                            .frame(width: 34, height: bandY + 8)
                            .position(x: x, y: (bandY - 8) / 2 + 4)
                    }
                }
            }
        }
    }
}
