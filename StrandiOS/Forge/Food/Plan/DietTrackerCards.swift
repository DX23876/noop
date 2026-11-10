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
    /// The profile's sex, for recomposition's fitness photo; nil keeps the statue.
    var male: Bool?

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
            if case .recomp(let r) = progress {
                DietRecompLines(recomp: r, compact: compact)
            }
        }
        .forgeCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var picture: String {
        switch progress {
        case .way(let w): DietArt.stage(w.stage)
        case .hold: DietArt.holding
        case .recomp: male == nil ? DietArt.recomp : DietArt.goal(.gain, male: male)
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
        case .recomp(let r): r.working ? String(localized: "Reshaping") : String(localized: "Recomposition")
        }
    }

    private var detail: String {
        switch progress {
        case .way(let w):
            if w.stage == .goal { return String(localized: "Your trend is at \(DietText.kg(w.trendKg)). Forge now plans for holding it.") }
            return String(localized: "\(DietText.kg(w.doneKg)) done, \(DietText.kg(w.leftKg)) to go.")
        case .recomp(let r):
            if r.working { return String(localized: "Fat is going down and strength up, at about the same weight.") }
            if !r.weightSteady { return String(localized: "Your weight has moved more than planned; Forge adjusts the calories.") }
            return String(localized: "Recomposition takes months. These three lines show whether it is working.")
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

/// Recomposition's three signs, each in words with an arrow: weight steady, fat (or the waist) down, strength up.
/// A line without readings says how to get them instead of showing nothing.
struct DietRecompLines: View {
    let recomp: DietProgress.Recomp
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(String(localized: "Weight"), ok: recomp.weightSteady, symbol: recomp.weightSteady ? "equal.circle.fill" : "exclamationmark.circle.fill",
                 value: String(localized: "\(DietText.kg(recomp.trendKg)), started at \(DietText.kg(recomp.startKg))"))
            if let bf = recomp.bodyFatChange {
                line(String(localized: "Body fat"), ok: bf < -0.3, symbol: bf < 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                     value: String(localized: "\(signed(bf, decimals: 1)) percentage points"))
            } else if let waist = recomp.waistChangeCm {
                line(String(localized: "Waist"), ok: waist < -0.5, symbol: waist < 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill",
                     value: "\(signed(waist, decimals: 1)) cm")
            } else if !compact {
                line(String(localized: "Body fat"), ok: nil, symbol: "ruler",
                     value: String(localized: "Measure body fat or your waist on the Body page now and then."))
            }
            if let strength = recomp.strengthChangePercent {
                line(String(localized: "Strength"), ok: strength > 1, symbol: strength >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                     value: "\(signed(strength, decimals: 0)) %")
            } else if !compact {
                line(String(localized: "Strength"), ok: nil, symbol: "dumbbell",
                     value: String(localized: "Log your strength sessions, and your main lifts show here."))
            }
        }
        .padding(.horizontal, 4)
    }

    private func signed(_ value: Double, decimals: Int) -> String {
        let text = abs(value).formatted(.number.precision(.fractionLength(0...decimals)).locale(AppLanguage.activeLocale))
        return (value < 0 ? "−" : "+") + text
    }

    private func line(_ name: String, ok: Bool?, symbol: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(ok == nil ? ForgeColor.tertiary : ok == true ? ForgeColor.chargeInk : ForgeColor.effortInk)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.text)
            Spacer(minLength: 8)
            Text(value).font(.subheadline).foregroundStyle(ForgeColor.secondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
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
                    let point = WayCurve.point(atLength: stage.threshold, in: CGRect(origin: .zero, size: size))
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

    /// The point at `share` of the curve's length, the same measure `trim` uses, so the walked line ends exactly on
    /// the stone it reached.
    static func point(atLength share: Double, in rect: CGRect) -> CGPoint {
        let steps = 200
        let points = (0...steps).map { point(at: Double($0) / Double(steps), in: rect) }
        var lengths = [0.0]
        for i in 1...steps { lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let target = share.clamped01 * (lengths.last ?? 0)
        guard let i = lengths.firstIndex(where: { $0 >= target }), i > 0 else { return points[0] }
        let span = lengths[i] - lengths[i - 1]
        let f = span > 0 ? (target - lengths[i - 1]) / span : 0
        return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * f,
                       y: points[i - 1].y + (points[i].y - points[i - 1].y) * f)
    }

    /// The point at Bezier parameter `t` (0 start, 1 end).
    private static func point(at t: Double, in rect: CGRect) -> CGPoint {
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
                // The plan was set to stand on the scale, but the figure is gone for now: say so, and let it go back.
                if model.plan?.burnSource == .scale {
                    Text("Until then your plan uses what your strap measures.")
                        .font(.subheadline).foregroundStyle(ForgeColor.text)
                    Button(String(localized: "Back to the strap")) {
                        Task { await model.setBurnSource(.strap, repo: repo) }
                    }
                    .buttonStyle(.bordered)
                    .tint(ForgeColor.accent)
                }
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
private extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
#endif

#if os(iOS)
/// This week's suggestions for the plan (owner, 2026-11-10), each with its reason and one action. Taking one that
/// changes the plan goes through the same plan save as the planner; the others open where the habit is kept up.
struct DietAdviceCard: View {
    let model: ForgeFoodModel
    var proteinFoods: () -> Void = {}

    var body: some View {
        if !model.advice.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Suggestions this week", systemImage: "lightbulb.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
                ForEach(model.advice) { s in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(DietText.adviceTitle(s.kind)).font(.headline).foregroundStyle(ForgeColor.text)
                        Text(DietText.adviceReason(s.kind)).font(.subheadline).foregroundStyle(ForgeColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            action(s)
                            Button("Not this week") { withAnimation(.smooth) { model.dismissAdvice(s) } }
                                .buttonStyle(.borderless).foregroundStyle(ForgeColor.secondary)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    if s.id != model.advice.last?.id { Divider() }
                }
            }
            .forgeCard(padding: 14)
            .transition(.opacity)
        }
    }

    @ViewBuilder private func action(_ s: DietAdvice.Suggestion) -> some View {
        switch s.action {
        case .addKcal, .takeBreakWeek:
            Button(DietText.adviceAction(s.action)) { withAnimation(.smooth) { model.takeAdvice(s) } }
                .buttonStyle(.borderedProminent).tint(ForgeColor.accent)
        case .showProteinFoods:
            Button(DietText.adviceAction(s.action), action: proteinFoods)
                .buttonStyle(.borderedProminent).tint(ForgeColor.accent)
        case .openWeight:
            NavigationLink(value: TabRoute.weight) { Text(DietText.adviceAction(s.action)) }
                .buttonStyle(.borderedProminent).tint(ForgeColor.accent)
        case .openLog:
            NavigationLink(value: ForgeRoute.foodAdd) { Text(DietText.adviceAction(s.action)) }
                .buttonStyle(.borderedProminent).tint(ForgeColor.accent)
        }
    }
}
#endif
