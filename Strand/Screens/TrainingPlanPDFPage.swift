import SwiftUI
import StrandDesign
import StrandTraining

/// A complete, offline printable view of the user's current routines and weekly schedule.
/// Completed workouts, dates overridden for one week and tracker identifiers are intentionally absent.
struct TrainingPlanPDFPage: View {
    let plan: TrainingPlan
    let exercises: [TrainingExercise]
    let generatedOn: String

    private var exerciseById: [String: TrainingExercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space6) {
            header
            weeklySchedule
            if plan.routines.isEmpty {
                Text("No routines in this plan yet.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.vertical, NoopMetrics.space8)
            } else {
                ForEach(plan.routines) { routine in routineSection(routine) }
            }
            footer
        }
        .padding(NoopMetrics.space8)
        .frame(width: 612, alignment: .leading)
        .background(StrandPalette.surfaceBase)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("NOOP")
                    .font(StrandFont.caption.weight(.bold))
                    .foregroundStyle(StrandPalette.accent)
                    .tracking(2)
                Text("Training plan")
                    .font(StrandFont.title1.weight(.bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(String(format: String(localized: "Generated %@"), generatedOn))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(StrandPalette.metricCyan)
        }
    }

    private var weeklySchedule: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("WEEKLY SCHEDULE").strandOverline()
            VStack(spacing: 0) {
                ForEach(orderedWeekdays, id: \.rawValue) { day in
                    HStack(alignment: .top, spacing: NoopMetrics.space3) {
                        Text(dayName(day))
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 92, alignment: .leading)
                        Text(routineNames(for: day))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, NoopMetrics.space2)
                    if day != orderedWeekdays.last { Divider().overlay(StrandPalette.hairline) }
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
            .background(StrandPalette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    private func routineSection(_ routine: TrainingRoutine) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text(routine.title)
                    .font(StrandFont.title2.weight(.bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("\(routine.exercises.count) exercises")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let notes = routine.notes, !notes.isEmpty {
                Text(notes).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(routine.exercises.enumerated()), id: \.element.id) { index, planned in
                    exerciseRow(planned, number: index + 1, routine: routine)
                    if index < routine.exercises.count - 1 { Divider().overlay(StrandPalette.hairline) }
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
            .background(StrandPalette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
    }

    private func exerciseRow(_ planned: RoutineExercise, number: Int,
                             routine: TrainingRoutine) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Text("\(number)")
                .font(StrandFont.caption.weight(.bold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(exerciseById[planned.exerciseId]?.title ?? planned.exerciseId)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(setSummary(planned))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                let progression = planned.progression ?? routine.defaultProgression
                if progression.policy != .off && !routine.excludeFromProgression {
                    Text(String(format: String(localized: "Progression: %@"),
                                progressionName(progression.policy)))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.metricCyan)
                }
                if let note = planned.note, !note.isEmpty {
                    Text(note).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            Text(String(format: String(localized: "Rest %lld s"), Int64(planned.restSeconds)))
                .font(StrandFont.caption.monospacedDigit())
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, NoopMetrics.space3)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Divider().overlay(StrandPalette.hairline)
            Text("Created locally by NOOP. This plan contains no completed workouts or tracker identifiers.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var orderedWeekdays: [TrainingWeekday] {
        let mondayFirst = TrainingWeekday.allCases.sorted { $0.rawValue < $1.rawValue }
        guard plan.weekStartsOn == .sunday, let sunday = mondayFirst.last else { return mondayFirst }
        return [sunday] + mondayFirst.dropLast()
    }

    private func routineNames(for day: TrainingWeekday) -> String {
        let byId = Dictionary(uniqueKeysWithValues: plan.routines.map { ($0.id, $0.title) })
        let names = (plan.schedule[day] ?? []).compactMap { byId[$0] }
        return names.isEmpty ? String(localized: "Rest") : names.joined(separator: " + ")
    }

    private func dayName(_ day: TrainingWeekday) -> String {
        switch day {
        case .monday: return String(localized: "Monday")
        case .tuesday: return String(localized: "Tuesday")
        case .wednesday: return String(localized: "Wednesday")
        case .thursday: return String(localized: "Thursday")
        case .friday: return String(localized: "Friday")
        case .saturday: return String(localized: "Saturday")
        case .sunday: return String(localized: "Sunday")
        }
    }

    private func setSummary(_ planned: RoutineExercise) -> String {
        let work = planned.sets.filter { $0.phase == .work }
        let warmups = planned.sets.count - work.count
        var parts = [String(format: String(localized: "%lld work sets"), Int64(work.count))]
        if warmups > 0 {
            parts.append(String(format: String(localized: "%lld warm-up sets"), Int64(warmups)))
        }
        if let range = work.first.flatMap({ set -> String? in
            guard let low = set.repsMin else { return nil }
            return set.repsMax.map { low == $0 ? "\(low) reps" : "\(low)–\($0) reps" } ?? "\(low) reps"
        }) { parts.append(range) }
        if let weight = work.compactMap(\.targetWeightKg).first {
            parts.append("\(weight.formatted(.number.precision(.fractionLength(0...2)))) kg")
        }
        if planned.supersetId != nil { parts.append(String(localized: "Superset")) }
        return parts.joined(separator: " · ")
    }

    private func progressionName(_ policy: ProgressionPolicy) -> String {
        switch policy {
        case .off: return String(localized: "Off")
        case .linear: return String(localized: "Linear")
        case .doubleProgression: return String(localized: "Double progression")
        case .greyskullLP: return "Greyskull LP"
        case .time: return String(localized: "Time")
        }
    }
}
