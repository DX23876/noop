import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandImport
import WhoopStore

// MARK: - One measurement site, over time
//
// The Body page answers "where am I now" across every site at once. This answers the other question —
// "what has this one been doing" — and it gets its own screen because the honest version needs room:
// a chart the points can actually be read off, the change across the window, and the individual
// readings with the dates and sources they came from.
//
// The reading list matters more here than it looks. Circumference data is method-sensitive, so when a
// series does something surprising the useful question is usually "what happened on that day" rather
// than "what does the trend say" — and that is answerable only if the individual readings are visible
// rather than smoothed into a line.

struct BodySiteDetailView: View {
    let siteKey: String
    @ObservedObject var model: BodyModel

    @EnvironmentObject private var repo: Repository
    @State private var editing: EditableReading?
    @State private var pendingDeletion: BodyReading?

    private var series: [BodyReading] { model.metrics.series(siteKey) }

    private var unit: String {
        MarkerCatalog.definition(for: siteKey)?.canonicalUnit ?? "cm"
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                headline
                if series.count >= 2 { chartCard } else { notEnoughCard }
                if let guidance = model.guidance(siteKey) { guidanceCard(guidance) }
                readingsCard
            }
            .padding(NoopMetrics.gap)
            DemoScrollBottomAnchor()
        }
        .navigationTitle(model.label(siteKey))
        .sheet(item: $editing) { editable in
            ReadingEditSheet(reading: editable.reading, siteKey: siteKey, unit: unit,
                             label: model.label(siteKey)) { value, date in
                await repo.updateBodyMeasurement(id: editable.id, markerKey: siteKey,
                                                 value: value, takenAt: date)
                await model.load(repo: repo)
            }
        }
        // A confirmation, because a deleted measurement cannot be re-measured — the day it belonged to
        // is gone. The dialog names the value and the date so nobody removes the wrong row.
        .confirmationDialog(
            pendingDeletion.map {
                String(localized: "Delete the \($0.value.formatted(.number.precision(.fractionLength(1)))) \(unit) reading from \(dayText($0.day))?")
            } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let id = pendingDeletion?.id else { return }
                    Task {
                        await repo.deleteBodyMeasurement(id: id)
                        await model.load(repo: repo)
                        pendingDeletion = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("This measurement cannot be taken again — the day it belongs to has passed.")
            }
        .task { await scrollToDemoBottom(proxy) }
        }
    }

    private var headline: some View {
        NoopCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.last.map {
                        "\($0.value.formatted(.number.precision(.fractionLength(1)))) \(unit)"
                    } ?? "—")
                        .font(StrandFont.number(30)).foregroundStyle(StrandPalette.textPrimary)
                    Text(series.last.map { dayText($0.day) } ?? " ")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                if let change = model.siteChange(siteKey) {
                    VStack(alignment: .trailing, spacing: 2) {
                        // Signed, and NOT coloured by direction. Whether a bigger arm or a smaller
                        // waist is the good news depends entirely on the site and on what the wearer
                        // is training for, and the app has no business deciding that for them.
                        Text("\(change > 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                            .font(StrandFont.number(20))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("over \(series.count) readings")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private var chartCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                SectionHeader("History", overline: LocalizedStringKey(model.label(siteKey)))
                TrendChart(points: points,
                           gradient: Gradient(colors: [StrandPalette.metricCyan.opacity(0.35),
                                                       StrandPalette.metricCyan]),
                           valueRange: valueRange, showsArea: false, height: 190,
                           valueFormat: { "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" },
                           accessibilityLabel: model.label(siteKey))
            }
        }
    }

    private var notEnoughCard: some View {
        NoopCard {
            Text("One reading so far. A second one gives this site a trend to draw.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func guidanceCard(_ text: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader("How to measure it", overline: "Method")
                Text(text).font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Measured a different way, this number moves further than a month of training does. Consistency beats precision here.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readingsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                SectionHeader("Every reading", overline: LocalizedStringKey("\(series.count)"))
                ForEach(Array(series.reversed().enumerated()), id: \.offset) { _, reading in
                    HStack {
                        Text(dayText(reading.day)).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text(sourceLabel(reading.source))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text("\(reading.value.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 76, alignment: .trailing)
                        // Only readings NOOP owns get the controls. An Apple Health row is edited in
                        // Health; offering a pencil that cannot deliver would be worse than no pencil.
                        if reading.id != nil {
                            Menu {
                                Button {
                                    if let id = reading.id {
                                        editing = EditableReading(id: id, reading: reading)
                                    }
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) { pendingDeletion = reading } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                            .accessibilityLabel("Edit or delete this reading")
                        } else {
                            Spacer().frame(width: 24)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private var points: [TrendPoint] {
        series.compactMap { reading in
            WeightSeries.date(forDay: reading.day).map {
                // Segment by SOURCE, so a scan and a tape reading never join into one line.
                TrendPoint(date: $0, value: reading.value, segment: reading.source)
            }
        }
    }

    private var valueRange: ClosedRange<Double> {
        let values = series.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.2, 0.5)
        return (low - pad)...(high + pad)
    }

    private func dayText(_ day: String) -> String {
        guard let date = WeightSeries.date(forDay: day) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "manual": return String(localized: "Entered")
        case "profile": return String(localized: "From your profile")
        case Repository.appleHealthSource: return String(localized: "Apple Health")
        case "dexa": return String(localized: "DEXA")
        case "caliper": return String(localized: "Caliper")
        default: return source
        }
    }
}


/// Correcting one stored reading.
///
/// Both the value and the date are editable, because the commonest correction is not a mistyped number
/// — it is a measurement entered a day or two after it was taken, which quietly puts it on the wrong
/// point of the trend.
struct ReadingEditSheet: View {
    let reading: BodyReading
    let siteKey: String
    let unit: String
    let label: String
    let onSave: (Double, Date) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var date: Date

    init(reading: BodyReading, siteKey: String, unit: String, label: String,
         onSave: @escaping (Double, Date) async -> Void) {
        self.reading = reading
        self.siteKey = siteKey
        self.unit = unit
        self.label = label
        self.onSave = onSave
        _text = State(initialValue: reading.value.formatted(.number.precision(.fractionLength(1))))
        _date = State(initialValue: Date(timeIntervalSince1970: TimeInterval(reading.takenAt)))
    }

    private var parsed: Double? {
        Double(text.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(label)
                        Spacer()
                        TextField(unit, text: $text)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                        Text(unit).foregroundStyle(StrandPalette.textTertiary)
                    }
                    DatePicker("Taken", selection: $date, in: ...Date())
                } footer: {
                    Text("Changing the date moves this reading on the trend. A measurement entered late belongs to the day it was taken, not the day it was typed.")
                }
            }
            .navigationTitle("Edit reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let value = parsed else { return }
                        Task { await onSave(value, date); dismiss() }
                    }
                    .disabled(parsed == nil)
                }
            }
        }
    }
}

/// A reading the edit sheet is open on.
///
/// A wrapper rather than making `BodyReading` itself `Identifiable`: the type already carries an
/// OPTIONAL `id` (nil for readings NOOP does not own), and a same-named non-optional conformance both
/// collides with it and — as first written here — recurses into itself forever. Only rows with a real
/// id can be edited anyway, so the wrapper carries it unwrapped and the impossible case disappears.
struct EditableReading: Identifiable {
    let id: String
    let reading: BodyReading
}
