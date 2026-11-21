#if os(iOS)
import SwiftUI
import StrandCore

/// The day's food note on the Food page (owner, 2026-11-21): the day's note large, the week's and month's beside
/// it, and under it where the day stands against the goal. The note and the goal stay two readings: good food can
/// be over the goal and a kept goal can be poor food. Tapping opens what the notes are made of.
struct FoodNoteCard: View {
    let day: Result<FoodQuality.Note, FoodQuality.MissingError>?
    let week: FoodQuality.Note?
    let month: FoodQuality.Note?
    let goal: FoodGoalState.Day?
    /// Today is still being eaten: the plate above already shows its energy and macros, so the card only speaks of
    /// the goal once the day is over it.
    var isToday = false
    let streakDays: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 16) {
                // What the number is about, said before the number: a title, one sentence and the still life of good
                // food the detail page opens on.
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Nutrition quality", systemImage: "leaf.fill")
                            .font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                            .labelStyle(TintedIconLabel(tint: ForgeColor.nutrientLeaf))
                        Text("How healthy you are eating, out of 10")
                            .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                    }
                    Spacer(minLength: 8)
                    // The food sits on the right of the photo: the square shows that part.
                    Image("foodScoreHero").resizable().scaledToFill()
                        .frame(width: 64, height: 64, alignment: .trailing)
                        .clipShape(.rect(cornerRadius: ForgeRadius.inner))
                        .accessibilityHidden(true)
                }
                HStack(alignment: .center, spacing: 16) {
                    FoodQualityRing(score: note?.score, size: 88)
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note?.provisional == true ? String(localized: "Today so far") : String(localized: "Day"))
                                .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                            Text(note.map { FoodText.noteWord($0.score) } ?? "–")
                                .font(ForgeFont.cardTitle).foregroundStyle(FoodQualityRing.tint(note?.score))
                        }
                        HStack(spacing: 16) {
                            small(String(localized: "Week"), week)
                            small(String(localized: "Month"), month)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ForgeColor.tertiary)
                }
                let showsGoal = goal.map { !isToday || $0.energy == .over } ?? false
                if showsGoal || streakDays >= 2 {
                    HStack(spacing: 8) {
                        if let goal, showsGoal {
                            chip(energyText(goal), symbol: "flame.fill", ok: goal.energy == .inRange)
                            if !isToday, let protein = goal.proteinMet {
                                chip(String(localized: "Protein"), symbol: protein ? "checkmark" : "minus", ok: protein)
                            }
                            if !isToday, let carbs = goal.carbsWithinCap {
                                chip(String(localized: "Carbs"), symbol: carbs ? "checkmark" : "exclamationmark", ok: carbs)
                            }
                        }
                        Spacer(minLength: 0)
                        if streakDays >= 2 {
                            Label("\(streakDays)", systemImage: "flame")
                                .font(ForgeFont.caption.weight(.semibold)).foregroundStyle(ForgeColor.effortInk)
                                .accessibilityLabel(Text("\(streakDays) days logged in a row"))
                        }
                    }
                }
                if let line = statusLine {
                    Text(line).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .forgeCard(radius: ForgeRadius.card, padding: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.smooth, value: note?.score)
    }

    private var note: FoodQuality.Note? { if case .success(let n) = day { n } else { nil } }

    private func small(_ title: String, _ note: FoodQuality.Note?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            Text(note.map { FoodText.note($0.score) } ?? "–")
                .font(ForgeFont.rounded(20, .semibold)).foregroundStyle(FoodQualityRing.tint(note?.score)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, symbol: String, ok: Bool) -> some View {
        Label(text, systemImage: symbol)
            .font(ForgeFont.caption.weight(.semibold))
            .foregroundStyle(ok ? ForgeColor.chargeInk : ForgeColor.effortInk)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(ForgeColor.fill, in: .capsule)
    }

    private func energyText(_ goal: FoodGoalState.Day) -> String {
        switch goal.energy {
        case .inRange: String(localized: "On goal")
        case .over: String(localized: "Over goal")
        case .under: String(localized: "Under goal")
        case .belowFloor: String(localized: "Too little")
        }
    }

    /// Why the day has no note yet, or how sure it is.
    private var statusLine: String? {
        switch day {
        case .failure(let error):
            switch error.reason {
            case .nothing: return String(localized: "The day's note appears once you log food.")
            case .tooLittle(let logged, let needed):
                return String(localized: "The note counts from half your usual day: \(FoodText.kcal(logged)) of \(FoodText.kcal(needed)) kcal so far.")
            }
        case .success(let note):
            if note.uncertain {
                return String(localized: "\(FoodText.percent(1 - note.placedShare)) of the calories have no food group, so the note is uncertain.")
            }
            if note.placedShare < 0.995 {
                return String(localized: "\(FoodText.percent(1 - note.placedShare)) of the calories have no food group.")
            }
            return nil
        case nil:
            return nil
        }
    }
}

/// The note as a ring that fills to 10, in a colour that says how good it is, the note itself inside.
struct FoodQualityRing: View {
    let score: Double?
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            Circle().stroke(ForgeColor.fill, lineWidth: size * 0.1)
            Circle().trim(from: 0, to: min(1, (score ?? 0) / 10))
                .stroke(Self.tint(score), style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map(FoodText.note) ?? "–")
                    .font(ForgeFont.rounded(size * 0.3, .bold)).foregroundStyle(ForgeColor.text)
                    .monospacedDigit().contentTransition(.numericText())
                Text(verbatim: "/ 10").font(.caption2).foregroundStyle(ForgeColor.secondary)
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: score)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(score.map { "\(FoodText.note($0)) / 10, \(FoodText.noteWord($0))" } ?? "–"))
    }

    /// Green from 7.5, yellow from 5.5, orange below: the colour says the word before it is read.
    static func tint(_ score: Double?) -> Color {
        guard let score else { return ForgeColor.secondary }
        if score >= 7.5 { return ForgeColor.nutrientLeaf }
        if score >= 5.5 { return ForgeColor.nutrientSun }
        return ForgeColor.effort
    }
}

/// A label whose icon takes its own colour while the title keeps the text's.
private struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
#endif
