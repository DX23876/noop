import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Switching the basal formula, with what it rests on stated
//
// A formula change moves the basal rate by roughly 50 to 200 kcal a day. An unexplained step that size
// in an energy curve reads as a bug — and the wearer is right to read it that way. So the switch is
// confirmed rather than toggled, the sheet states the size of the step before it happens, and it names
// what the new formula depends on.
//
// The honesty that matters most here: Katch-McArdle is only better when the body-fat number is good.
// On a tape estimate carrying ±4 percentage points its error can be comparable to the formula it
// replaces. Offering it silently as an upgrade would be the wrong claim.

struct FormulaSwitchSheet: View {
    @ObservedObject var model: EnergyPlanModel
    let target: BasalFormula
    let profile: UserProfile
    let onSwitched: () async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if let delta = model.switchDelta(to: target, profile: profile) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(delta >= 0
                                 ? String(localized: "Your basal rate rises by \(Int(delta.rounded())) kcal a day")
                                 : String(localized: "Your basal rate falls by \(Int(abs(delta).rounded())) kcal a day"))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("From today onward. Days already scored keep the formula that applied then — this never rewrites history.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if target.needsBodyFat {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What this rests on")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(restsOnText)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("A step in the curve at today's date is this change, not a measurement change. The Energy screen labels it.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(NoopMetrics.gap)
            }
            .navigationTitle("Change formula")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Change") {
                        EnergyPlanStore.switchFormula(to: target, effectiveFrom: model.today)
                        Task { await onSwitched(); dismiss() }
                    }
                }
            }
        }
    }

    /// Names the source of the body-fat figure, because Katch-McArdle is only as good as it is.
    private var restsOnText: String {
        guard let reading = model.bodyFatToday else {
            return String(localized: "This formula needs a body-fat reading, and there is none yet.")
        }
        switch reading.source {
        case "dexa":
            return String(localized: "A DEXA reading of \(reading.value.formatted(.number.precision(.fractionLength(1)))) %. That is the strongest input this formula can have.")
        case "caliper", "bia", "inbody":
            return String(localized: "A measured reading of \(reading.value.formatted(.number.precision(.fractionLength(1)))) %. Good enough to work from, though less certain than a scan.")
        case "navy":
            return String(localized: "A tape estimate of \(reading.value.formatted(.number.precision(.fractionLength(1)))) %, which carries about ±4 percentage points. On a number that uncertain, this formula is not reliably better than the one it replaces — it is a different kind of wrong, not a smaller one.")
        default:
            return String(localized: "A reading of \(reading.value.formatted(.number.precision(.fractionLength(1)))) %. How much this formula improves on the last one depends entirely on how that figure was obtained.")
        }
    }
}

// MARK: - One number for one day
//
// No food database, and deliberately so: that is a separate app and would need a server this project
// does not have. The balance tier needs one figure per day and nothing more — and for a strap-only
// setup it is the only remaining way to check the level at all.

struct IntakeEntrySheet: View {
    let onSave: (Double, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $day, in: ...Date(),
                               displayedComponents: .date)
                    HStack {
                        Text("Calories in")
                        Spacer()
                        TextField("kcal", text: $text)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                    }
                } footer: {
                    Text("A fallback for a day Apple Health did not receive. NOOP ships no food database and is not trying to be a diary — anything you log in a nutrition app that syncs to Health already counts here without being retyped.")
                }
            }
            .navigationTitle("Intake")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let kcal = Double(text.replacingOccurrences(of: ",", with: ".")),
                              kcal > 0 else { return }
                        Task {
                            await onSave(kcal, Repository.localDayKey(day))
                            dismiss()
                        }
                    }
                    .disabled(Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 <= 0)
                }
            }
        }
    }
}
