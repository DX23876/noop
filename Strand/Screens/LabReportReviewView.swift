import SwiftUI
import StrandDesign
import StrandImport

/// Mandatory local review between report extraction and the Lab Book. This is intentionally a simple
/// confirmation surface: it presents what was recognised, lets the user omit candidates and choose the
/// report date, but makes no clinical statement or automatic write.
struct LabReportReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let candidates: [LabReportTextCandidate]
    let onSave: (Date, [LabReportTextCandidate]) async -> Void

    @State private var selectedIDs: Set<String>
    @State private var reportDate = Date()
    @State private var saving = false

    init(candidates: [LabReportTextCandidate],
         onSave: @escaping (Date, [LabReportTextCandidate]) async -> Void) {
        self.candidates = candidates
        self.onSave = onSave
        _selectedIDs = State(initialValue: Set(candidates.map(\.id)))
    }

    private var selected: [LabReportTextCandidate] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        ScreenScaffold(title: "Review report readings", subtitle: "Nothing is saved until you confirm.") {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("These are local text matches from the PDF, not medical interpretations. Check each value against your report and deselect anything you do not want to keep.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                DatePicker("Report date", selection: $reportDate, displayedComponents: .date)
                    .font(StrandFont.subhead)

                ForEach(candidates) { candidate in
                    Toggle(isOn: Binding(
                        get: { selectedIDs.contains(candidate.id) },
                        set: { included in
                            if included { selectedIDs.insert(candidate.id) }
                            else { selectedIDs.remove(candidate.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MarkerCatalog.definition(for: candidate.markerKey)?.displayName ?? candidate.markerKey)
                                .font(StrandFont.subhead)
                            Text("\(LabBookFormat.value(candidate.value, key: candidate.markerKey)) \(candidate.unit)")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                HStack(spacing: 10) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.noopSecondary)
                    Button(saving ? "Saving…" : "Save \(selected.count) reading\(selected.count == 1 ? "" : "s")") {
                        saving = true
                        Task {
                            await onSave(reportDate, selected)
                            saving = false
                            dismiss()
                        }
                    }
                    .buttonStyle(.noopPrimary)
                    .disabled(selected.isEmpty || saving)
                }
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 520, height: 620)
        #endif
    }
}
