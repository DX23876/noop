#if os(iOS)
import SwiftUI
import StrandCore

/// What a food note is made of (owner, 2026-11-21): the day's, the week's or the month's, ten parts each up to ten
/// points in everyday words, and the last eight weeks as a trend. Highly processed food is shown below on its own,
/// since the index does not count it.
struct FoodScoreView: View {
    enum Span: String, CaseIterable, Identifiable { case day, week, month; var id: String { rawValue } }

    let day: FoodQuality.Note?
    let week: FoodQuality.Note?
    let month: FoodQuality.Note?
    let trend: [FoodQuality.Note]
    let male: Bool
    @State private var span: Span = .day

    init(day: FoodQuality.Note?, week: FoodQuality.Note?, month: FoodQuality.Note?, trend: [FoodQuality.Note], male: Bool) {
        self.day = day; self.week = week; self.month = month; self.trend = trend; self.male = male
        _span = State(initialValue: day != nil ? .day : week != nil ? .week : .month)
    }

    private var note: FoodQuality.Note? {
        switch span {
        case .day: day
        case .week: week
        case .month: month
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Span", selection: $span) {
                    Text("Day").tag(Span.day)
                    Text("Week").tag(Span.week)
                    Text("Month").tag(Span.month)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                // A still life of a balanced week behind the number, light or dark with the appearance; the food sits right,
                // the number on the calm left in the page's own text colours.
                ZStack(alignment: .leading) {
                    Image("foodScoreHero").resizable().scaledToFill()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .frame(height: 200)
                        .clipped()
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(note.map { FoodText.note($0.score) } ?? "–").font(ForgeFont.rounded(56, .bold))
                                .foregroundStyle(ForgeColor.text).monospacedDigit().contentTransition(.numericText())
                            Text(verbatim: "/ 10").font(.headline).foregroundStyle(ForgeColor.secondary)
                        }
                        if let note {
                            Text(FoodText.noteWord(note.score)).font(.headline).foregroundStyle(ForgeColor.text)
                        }
                        Text(caption).font(.footnote).foregroundStyle(ForgeColor.secondary)
                    }
                    // The calm left part of the photo only, so the words never run over the food.
                    .frame(maxWidth: 170, alignment: .leading)
                    .padding(.leading, 20)
                    .accessibilityElement(children: .combine)
                }
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(footer)
            }
            if trend.count >= 2 {
                Section {
                    FoodNoteTrend(notes: trend)
                } header: {
                    Text("Last 8 weeks")
                }
            }
            if let note {
                // Like a ledger: what adds to the note grows right of the middle line, what costs points grows left.
                Section {
                    ForEach(note.parts.filter { !$0.component.isLimit }.sorted { $0.points > $1.points }, id: \.component) { part in
                        row(part)
                    }
                } header: {
                    Text("Adds points")
                }
                Section {
                    ForEach(note.parts.filter(\.component.isLimit).sorted { $0.points < $1.points }, id: \.component) { part in
                        row(part)
                    }
                } header: {
                    Text("Costs points")
                } footer: {
                    Text("These start at full points and lose them as the amount rises.")
                }
                if let share = note.processedShare {
                    Section {
                        LabeledContent("Highly processed food", value: String(localized: "\(FoodText.percent(share)) of calories"))
                    } footer: {
                        Text("Counted on its own, not inside the note. Known only for products that carry a processing class.")
                    }
                }
            }
        }
        .animation(.smooth, value: span)
        .navigationTitle("Nutrition quality")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var caption: String {
        guard let note else {
            return span == .day ? String(localized: "No note for this day yet") : String(localized: "Too few logged days yet")
        }
        switch span {
        case .day: return note.provisional ? String(localized: "Today so far") : String(localized: "This day")
        case .week: return String(localized: "From \(note.loggedDays) logged days of the last 7")
        case .month: return String(localized: "From \(note.loggedDays) logged days of the last 28")
        }
    }

    private var footer: String {
        switch span {
        case .day:
            String(localized: "The day's own food, with fish, nuts and pulses and meat read over the last seven days, since nobody eats them every day.")
        case .week, .month:
            String(localized: "The amounts of all the days added up, then scored once, as nutrition research does for more than one day. It describes your habit, so it can differ from the day notes.")
        }
    }

    private func row(_ part: FoodScore.Part) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(Self.thumbnail(part.component)).resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityHidden(true)
            details(part)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// A small still life for each part, from the meal pictures where one fits.
    static func thumbnail(_ c: FoodScore.Component) -> String {
        switch c {
        case .vegetables: "foodMotif_vegetables"
        case .fruit: "foodMotif_fruit"
        case .wholeGrains: "foodMotif_grains"
        case .nutsLegumes: "foodMotif_legumes"
        case .redMeat: "foodMotif_meat"
        case .processedMeat: "foodMotif_meat"
        case .fishOmega3: "foodMotif_fish"
        case .freeSugar: "foodMotif_sweets"
        case .satFat: "foodMotif_fats"
        case .sodium: "foodMotif_salt"
        case .alcohol: "foodMotif_alcohol"
        case .fiber: "foodMotif_vegetables"
        }
    }

    private func details(_ part: FoodScore.Part) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(FoodText.component(part.component)).font(.body).foregroundStyle(ForgeColor.text)
                Spacer()
                Text(signed(part)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(abs(effect(part)) < 0.05 ? ForgeColor.secondary : effect(part) > 0 ? ForgeColor.nutrientLeaf : ForgeColor.nutrientRed)
            }
            FoodScoreBar(effect: effect(part))

            Text("\(FoodText.componentAmount(part)) · \(FoodText.componentGoal(part.component, male: male))")
                .font(.footnote).foregroundStyle(ForgeColor.secondary)
        }
    }

    /// What the part did to the score: `FoodScore.Part.points` is signed, so there is nothing to work out here.
    private func effect(_ part: FoodScore.Part) -> Double { part.points }

    private func signed(_ part: FoodScore.Part) -> String {
        let e = effect(part)
        guard abs(e) >= 0.05 else { return "0" }
        return (e > 0 ? "+" : "−") + FoodText.grams(abs(e))
    }
}
#endif
