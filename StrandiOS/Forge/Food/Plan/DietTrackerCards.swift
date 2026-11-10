#if os(iOS)
import SwiftUI
import StrandCore

/// The way to the goal weight (owner, 2026-11-10): the picture of the stage reached, where the trend stands in
/// words, and a path with five stones. Holding shows the ridge and whether the trend stays within a kilogram.
/// `compact` is Today's card: the picture smaller, no forecast line.
struct DietProgressCard: View {
    let progress: DietProgress.Progress
    var forecastLine: String?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(picture).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: compact ? 110 : 160).clipped()
                .clipShape(.rect(cornerRadius: ForgeRadius.inner))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(ForgeFont.rounded(compact ? 20 : 24, .bold)).foregroundStyle(ForgeColor.text)
                Text(detail).font(.subheadline).foregroundStyle(ForgeColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact, let forecastLine {
                    Text(forecastLine).font(.subheadline).foregroundStyle(ForgeColor.secondary)
                }
            }
            .padding(.horizontal, 4)
            if case .way(let way) = progress {
                DietWayPath(fraction: way.fraction)
                    .frame(height: compact ? 34 : 44)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
            }
        }
        .forgeCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var picture: String {
        switch progress {
        case .way(let w): DietArt.stage(w.stage)
        case .hold: DietArt.holding
        }
    }

    private var title: String {
        switch progress {
        case .way(let w):
            switch w.stage {
            case .start: String(localized: "On your way")
            case .quarter: String(localized: "A quarter of the way")
            case .half: String(localized: "Halfway there")
            case .threeQuarter: String(localized: "Three quarters done")
            case .goal: String(localized: "Goal reached")
            }
        case .hold(let h): h.inRange ? String(localized: "Holding steady") : String(localized: "Off your usual weight")
        }
    }

    private var detail: String {
        switch progress {
        case .way(let w):
            if w.stage == .goal { return String(localized: "Your trend is at \(DietText.kg(w.trendKg)). Forge now plans for holding it.") }
            return String(localized: "\(DietText.kg(w.doneKg)) done, \(DietText.kg(w.leftKg)) to go.")
        case .hold(let h):
            if h.inRange {
                return h.weeksInRange >= 1
                    ? String(localized: "Within a kilogram of \(DietText.kg(h.startKg)) for \(h.weeksInRange) weeks.")
                    : String(localized: "Within a kilogram of \(DietText.kg(h.startKg)).")
            }
            return String(localized: "Your trend is at \(DietText.kg(h.trendKg)), \(DietText.kg(abs(h.trendKg - h.startKg))) from where you started.")
        }
    }
}

/// Five stones along a gently rising path; the walked part drawn strong, the stones reached filled.
struct DietWayPath: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                WayCurve().stroke(ForgeColor.fill, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                WayCurve().trim(from: 0, to: max(0.001, fraction))
                    .stroke(ForgeColor.chargeInk, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                ForEach(DietProgress.Stage.allCases, id: \.self) { stage in
                    let point = WayCurve.point(at: stage.threshold, in: CGRect(origin: .zero, size: size))
                    let reached = fraction + 1e-9 >= stage.threshold
                    Circle()
                        .fill(reached ? ForgeColor.chargeInk : ForgeColor.card)
                        .overlay(Circle().stroke(reached ? ForgeColor.chargeInk : ForgeColor.tertiary, lineWidth: 2))
                        .frame(width: stage == .goal ? 16 : 12, height: stage == .goal ? 16 : 12)
                        .position(point)
                }
            }
        }
        .animation(.smooth, value: fraction)
    }
}

/// A gentle S from the lower left to the upper right, inset so the stones at both ends fit.
private struct WayCurve: Shape {
    func path(in rect: CGRect) -> Path {
        let r = Self.inset(rect)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY), control1: CGPoint(x: r.midX, y: r.maxY),
                   control2: CGPoint(x: r.midX, y: r.minY))
        return p
    }

    static func inset(_ rect: CGRect) -> CGRect { rect.insetBy(dx: 8, dy: 8) }

    /// The point at `t` of the curve (0 start, 1 end), for placing the stones on it.
    static func point(at t: Double, in rect: CGRect) -> CGPoint {
        let r = inset(rect)
        let p0 = CGPoint(x: r.minX, y: r.maxY), p1 = CGPoint(x: r.midX, y: r.maxY)
        let p2 = CGPoint(x: r.midX, y: r.minY), p3 = CGPoint(x: r.maxX, y: r.minY)
        let u = 1 - t
        func mix(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            CGFloat(u * u * u) * a + CGFloat(3 * u * u * t) * b + CGFloat(3 * u * t * t) * c + CGFloat(t * t * t) * d
        }
        return CGPoint(x: mix(p0.x, p1.x, p2.x, p3.x), y: mix(p0.y, p1.y, p2.y, p3.y))
    }
}

/// The real burn from food and weight beside the strap's (owner, 2026-11-10), and the choice of which one the plan
/// stands on. Before enough completely logged days it says what is still missing, and why only those days count.
struct DietBurnCard: View {
    let model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your burn").font(.headline).foregroundStyle(ForgeColor.text)
                Spacer()
                Button("How this works", systemImage: "info.circle") { showInfo = true }
                    .labelStyle(.iconOnly).foregroundStyle(ForgeColor.secondary)
            }
            switch model.expenditure {
            case .estimate(let e):
                bars(e)
                Text(comparison(e)).font(.subheadline).foregroundStyle(ForgeColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("From \(e.completeDays) completely logged days and your weight trend.")
                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
                Button(model.plan?.burnSource == .scale ? String(localized: "Back to the strap") : String(localized: "Base the plan on it")) {
                    Task { await model.setBurnSource(model.plan?.burnSource == .scale ? .strap : .scale, repo: repo) }
                }
                .buttonStyle(.bordered)
                .tint(ForgeColor.accent)
            case .missing(let days, let weighIns):
                Text("For your real burn Forge needs \(DietExpenditure.minCompleteDays) days on which you logged everything, and \(DietExpenditure.minWeighIns) weigh-ins in four weeks. So far \(days) and \(weighIns).")
                    .font(.subheadline).foregroundStyle(ForgeColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Under a day's meals, mark it once you have logged everything.")
                    .font(.footnote).foregroundStyle(ForgeColor.secondary)
            case nil:
                EmptyView()
            }
        }
        .forgeCard(padding: 14)
        .sheet(isPresented: $showInfo) {
            ScrollView {
                ForgeExplainer(title: "How your real burn is found",
                               text: "Forge takes what you ate on the days you marked as completely logged and what your weight trend did over the same four weeks. Energy you did not burn shows up as weight, energy you burned beyond your food as weight lost. Days with forgotten snacks would make the burn look too low, so only marked days count. Your strap measures heart rate and movement and estimates from them, which can run high or low; the two side by side show which way.") {
                    Image(DietArt.explain("pace")).resizable().scaledToFill().frame(height: 170).clipped()
                        .clipShape(.rect(cornerRadius: ForgeRadius.card)).accessibilityHidden(true)
                }
                .padding(16)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func bars(_ e: DietExpenditure.Estimate) -> some View {
        let top = max(e.burnKcal, e.strapKcal ?? 0, 1)
        return VStack(alignment: .leading, spacing: 10) {
            bar(String(localized: "From your food and weight"), e.burnKcal, top, ForgeColor.chargeInk)
            if let strap = e.strapKcal { bar(String(localized: "Measured by your strap"), strap, top, ForgeColor.effortInk) }
        }
    }

    private func bar(_ label: String, _ kcal: Double, _ top: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(ForgeColor.secondary)
                Spacer()
                Text("\(FoodText.kcal(kcal)) kcal").font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ForgeColor.text)
            }
            GeometryReader { geo in
                Capsule().fill(ForgeColor.fill)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: geo.size.width * kcal / top)
                    }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func comparison(_ e: DietExpenditure.Estimate) -> String {
        guard let ratio = e.realToStrap else {
            return String(localized: "Your body burns about \(FoodText.kcal(e.burnKcal)) kcal a day.")
        }
        let percent = Int(((1 / ratio - 1) * 100).rounded())
        if abs(percent) < 3 { return String(localized: "Your strap and your scale agree.") }
        let amount = "\(abs(percent)) %"
        return percent > 0
            ? String(localized: "Your strap reads about \(amount) above what your scale shows.")
            : String(localized: "Your strap reads about \(amount) below what your scale shows.")
    }
}
#endif
