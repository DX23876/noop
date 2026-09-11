import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandImport
import WhoopStore

// MARK: - Recording one measurement session
//
// One sheet, one timestamp, n values, one optional note. That is how people actually measure — tape in
// hand, several sites in a row — and it is what makes a left/right comparison meaningful afterwards:
// both sides share an instant, so the difference is between two sites rather than between two days.
//
// GUIDANCE SITS AT THE POINT OF ENTRY, not behind an info button. Circumference data is almost entirely
// method noise when the method varies: a tape half an inch higher, or pulled tighter, moves the number
// further than a month of training does. Guidance read once and forgotten does not fix that; guidance
// visible while typing does.
//
// The previous value is shown as the field's placeholder. It is a reference point, never a default —
// an unfilled field saves nothing, so nobody can accidentally re-record last month's number as today's.

struct BodyCaptureSheet: View {
    @ObservedObject var model: BodyModel
    let onSaved: () async -> Void

    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @State private var takenAt = Date()
    @State private var entries: [String: String] = [:]
    @State private var bodyFatText = ""
    @State private var bodyFatSource = "dexa"
    @State private var note = ""
    @State private var saving = false

    /// Body-fat sources worth distinguishing. They are not the same measurement, so each keeps its own
    /// series rather than being averaged into one line.
    private let bodyFatSources = [
        ("dexa", String(localized: "DEXA")),
        ("caliper", String(localized: "Caliper")),
        ("bia", String(localized: "BIA scale")),
        ("inbody", String(localized: "InBody")),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Taken", selection: $takenAt, in: ...Date())
                } footer: {
                    Text("Every value in this sheet is stored at this one instant.")
                }

                Section("Weight") {
                    field(key: WhoopStore.bodyWeightMetricKey, unit: "kg")
                }

                Section {
                    HStack {
                        Text("Body fat")
                        Spacer()
                        TextField(placeholder(for: "body_fat"), text: $bodyFatText)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                        Text("%").foregroundStyle(StrandPalette.textTertiary)
                    }
                    Picker("Measured with", selection: $bodyFatSource) {
                        ForEach(bodyFatSources, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: {
                    Text("Body fat")
                } footer: {
                    Text("For a value you had measured. The tape estimate on the Body page is kept separate — a DEXA result and a circumference estimate are different measurements and never share a line.")
                }

                Section {
                    ForEach(MarkerCatalog.circumferenceKeys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            field(key: key, unit: "cm")
                            if let guidance = model.guidance(key) {
                                Text(guidance)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Circumferences")
                } footer: {
                    Text("Leave anything you did not measure empty. Only filled fields are saved.")
                }

                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical).lineLimit(1...4)
                }
            }
            .navigationTitle("Measure")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || !hasAnything)
                }
            }
        }
    }

    private func field(key: String, unit: String) -> some View {
        HStack {
            Text(model.label(key))
            Spacer()
            TextField(placeholder(for: key), text: Binding(
                get: { entries[key] ?? "" },
                set: { entries[key] = $0 }))
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            #if os(iOS)
                .keyboardType(.decimalPad)
            #endif
            Text(unit).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// The previous reading, shown as a reference. Never a default — see the file header.
    private func placeholder(for key: String) -> String {
        guard let reading = model.current(key) else { return "—" }
        return reading.value.formatted(.number.precision(.fractionLength(1)))
    }

    private var hasAnything: Bool {
        !parsed().isEmpty || parsedBodyFat() != nil
    }

    /// Filled fields only, parsed leniently enough to accept a comma decimal separator.
    private func parsed() -> [String: Double] {
        var values: [String: Double] = [:]
        for (key, text) in entries {
            let cleaned = text.replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, let value = Double(cleaned), value > 0, value.isFinite else {
                continue
            }
            values[key] = value
        }
        return values
    }

    private func parsedBodyFat() -> Double? {
        let cleaned = bodyFatText.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned),
              NavyBodyFat.plausibleRange.contains(value) else { return nil }
        return value
    }

    private func save() async {
        saving = true
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteOrNil = trimmedNote.isEmpty ? nil : trimmedNote

        let values = parsed()
        if !values.isEmpty {
            await repo.recordBodyMeasurements(values, takenAt: takenAt, source: "manual",
                                              note: noteOrNil)
        }
        // Body fat is written separately because it carries its OWN source. Folding it into the call
        // above would stamp a DEXA result as "manual" and lose the distinction the chart depends on.
        if let bodyFat = parsedBodyFat() {
            await repo.recordBodyMeasurements(["body_fat": bodyFat], takenAt: takenAt,
                                              source: bodyFatSource, note: noteOrNil)
        }
        await onSaved()
        saving = false
        dismiss()
    }
}
