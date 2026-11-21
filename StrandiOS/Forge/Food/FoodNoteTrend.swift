#if os(iOS)
import SwiftUI
import Charts
import StrandCore
import WhoopStore

/// The last weeks' notes as bars on a labelled 0 to 10 axis, each bar the seven days ending on its date.
struct FoodNoteTrend: View {
    let notes: [FoodQuality.Note]

    var body: some View {
        Chart(notes, id: \.day) { note in
            BarMark(x: .value("Week", label(note.day)), y: .value("Note", note.score), width: .ratio(0.6))
                .foregroundStyle(ForgeColor.nutrientLeaf.gradient)
                .clipShape(.rect(cornerRadius: 4))
                .annotation(position: .top) {
                    Text(FoodText.note(note.score)).font(.caption2.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
                        .monospacedDigit()
                }
        }
        .chartYScale(domain: 0...10)
        .chartYAxis { AxisMarks(values: [0, 5, 10]) }
        .frame(height: 160)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("Food note of the last weeks"))
    }

    private func label(_ day: String) -> String {
        guard let date = WeightSeries.date(forDay: day) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
#endif
