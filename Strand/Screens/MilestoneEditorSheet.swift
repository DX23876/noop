import SwiftUI
import StrandDesign

/// Move or remove one waypoint on a goal's route.
///
/// The app suggests the route; this is the half that makes it the user's. A moved waypoint is marked
/// `isCustom`, which is what stops a later re-suggest (after a changed target or date) from quietly
/// putting it back where the arithmetic wanted it.
///
/// An already-reached waypoint is shown but not editable: it is a record of something that happened,
/// and rewriting it would make the route a worse record than a plain list.
struct MilestoneEditorSheet: View {
    let edit: JourneyView.MilestoneEdit
    let unit: String
    var onChange: () -> Void

    @ObservedObject private var goalStore = CoachGoalStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double
    @State private var expectedDate: Date

    init(edit: JourneyView.MilestoneEdit, unit: String, onChange: @escaping () -> Void) {
        self.edit = edit
        self.unit = unit
        self.onChange = onChange
        _value = State(initialValue: edit.milestone.value)
        _expectedDate = State(initialValue: edit.milestone.expectedDate)
    }

    private var isReached: Bool { edit.milestone.achievedAt != nil }

    var body: some View {
        NavigationStack {
            Form {
                if isReached {
                    Section {
                        Text("Reached on \(edit.milestone.achievedAt!.formatted(.dateTime.day().month().year())). Waypoints you've already passed stay as they are — they're a record, not a plan.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    Section("Waypoint") {
                        HStack {
                            Text("Value")
                            Spacer()
                            TextField("Value", value: $value, format: .number)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .frame(maxWidth: 120)
                            Text(unit).foregroundStyle(StrandPalette.textTertiary)
                        }
                        DatePicker("Expected", selection: $expectedDate, displayedComponents: .date)
                    }
                    Section {
                        Button("Remove this waypoint", role: .destructive) {
                            goalStore.removeMilestone(goalId: edit.goalId, milestoneId: edit.milestone.id)
                            onChange()
                            dismiss()
                        }
                    } footer: {
                        Text("Removing a waypoint doesn't change your goal or its date — only the route to it.")
                    }
                }
            }
            .navigationTitle("Waypoint")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !isReached {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            goalStore.updateMilestone(goalId: edit.goalId, milestoneId: edit.milestone.id,
                                                      value: value, expectedDate: expectedDate)
                            onChange()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
