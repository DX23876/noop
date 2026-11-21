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
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    dayFigure
                    Spacer(minLength: 8)
                    small(String(localized: "Week"), week)
                    small(String(localized: "Month"), month)
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

    @ViewBuilder private var dayFigure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note?.provisional == true ? String(localized: "Today so far") : String(localized: "Day"))
                .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(note.map { FoodText.note($0.score) } ?? "–")
                    .font(ForgeFont.rounded(40, .bold)).foregroundStyle(ForgeColor.text)
                    .monospacedDigit().contentTransition(.numericText())
                Text(verbatim: "/ 10").font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
            }
            if let note {
                Text(FoodText.noteWord(note.score)).font(ForgeFont.caption.weight(.semibold)).foregroundStyle(ForgeColor.nutrientLeaf)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func small(_ title: String, _ note: FoodQuality.Note?) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title).font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            Text(note.map { FoodText.note($0.score) } ?? "–")
                .font(ForgeFont.rounded(20, .semibold)).foregroundStyle(ForgeColor.text).monospacedDigit()
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
#endif
