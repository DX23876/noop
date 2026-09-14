import Foundation

/// A small, self-contained plan file. Completed workouts and tracker identifiers are deliberately
/// excluded so sharing a routine never leaks health history or creates a second workout archive.
public struct TrainingPlanArchive: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var exportedAt: Int
    public var weekStartsOn: TrainingWeekStart
    public var routines: [TrainingRoutine]
    public var schedule: [TrainingWeekday: [UUID]]
    public var exercises: [TrainingExercise]

    public init(formatVersion: Int = 1,
                exportedAt: Int = Int(Date().timeIntervalSince1970),
                plan: TrainingPlan,
                exercises: [TrainingExercise]) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.weekStartsOn = plan.weekStartsOn
        self.routines = plan.routines
        self.schedule = plan.schedule
        let used = Set(plan.routines.flatMap { $0.exercises.map(\.exerciseId) })
        self.exercises = exercises.filter { used.contains($0.id) }
    }

    public var plan: TrainingPlan {
        TrainingPlan(routines: routines, schedule: schedule, overrides: [], weekStartsOn: weekStartsOn)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TrainingPlanArchive {
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.formatVersion == 1 else { throw TrainingExchangeError.unsupportedVersion }
        let exerciseIds = Set(archive.exercises.map(\.id))
        guard archive.routines.allSatisfy({ routine in
            !routine.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && routine.exercises.allSatisfy { exerciseIds.contains($0.exerciseId) }
        }) else { throw TrainingExchangeError.invalidPlan }
        return archive
    }
}

public struct TrainingHistoryImport: Equatable, Sendable {
    public var exercises: [TrainingExercise]
    public var workouts: [NativeWorkout]
    public var skippedRows: Int

    public init(exercises: [TrainingExercise], workouts: [NativeWorkout], skippedRows: Int) {
        self.exercises = exercises
        self.workouts = workouts
        self.skippedRows = skippedRows
    }
}

public enum TrainingCSVFormat: Sendable {
    case fitNotes
    case strong
    case automatic
}

public enum TrainingExchangeError: Error, Equatable {
    case unsupportedVersion
    case invalidPlan
    case invalidText
    case missingRequiredColumns
    case noUsableRows
}

/// Imports the common FitNotes and Strong CSV shapes into the same normalized workout model used by
/// NOOP's logger. The parser is intentionally header-driven: exports from different app versions can
/// reorder columns without silently assigning weight, reps or dates to the wrong fields.
public enum TrainingCSVImporter {
    public static func parse(_ data: Data, format: TrainingCSVFormat = .automatic,
                             existingExercises: [TrainingExercise] = []) throws -> TrainingHistoryImport {
        guard let text = String(data: data, encoding: .utf8) else { throw TrainingExchangeError.invalidText }
        let table = CSVTable(text)
        guard !table.headers.isEmpty else { throw TrainingExchangeError.invalidText }
        guard let dateColumn = table.column(named: ["date", "startdate", "workoutdate"]),
              let exerciseColumn = table.column(named: ["exercise", "exercisename"]) else {
            throw TrainingExchangeError.missingRequiredColumns
        }

        let titleColumn = table.column(named: ["workoutname", "workout", "routine", "category"])
        let weightColumn = table.column(named: ["weightkg", "weightkgs", "weight"])
        let repsColumn = table.column(named: ["reps", "repetitions"])
        let rpeColumn = table.column(named: ["rpe"])
        let durationColumn = table.column(named: ["seconds", "durationseconds", "duration", "time"])
        let distanceColumn = table.column(named: ["distancem", "distance"])
        let notesColumn = table.column(named: ["notes", "note", "workoutnotes"])

        var knownByName = Dictionary(uniqueKeysWithValues: existingExercises.map {
            (normalizeName($0.title), $0)
        })
        var importedById: [String: TrainingExercise] = [:]
        var grouped: [SessionKey: SessionAccumulator] = [:]
        var skipped = 0

        for row in table.rows {
            let rawDate = table.value(row, at: dateColumn)
            let rawExercise = table.value(row, at: exerciseColumn).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = parseDate(rawDate), !rawExercise.isEmpty else { skipped += 1; continue }

            let normalized = normalizeName(rawExercise)
            let exercise: TrainingExercise
            if let existing = knownByName[normalized] {
                exercise = existing
            } else {
                let id = "imported:\(stableSlug(rawExercise))"
                let mode: TrainingMeasurementMode = weightColumn == nil ? .repetitions : .weightReps
                exercise = TrainingExercise(id: id, title: rawExercise, mode: mode,
                                            source: .imported, sourceId: rawExercise)
                knownByName[normalized] = exercise
                importedById[id] = exercise
            }

            let sessionTitle = titleColumn.map { table.value(row, at: $0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? "Imported workout"
            let day = dayFormatter.string(from: date)
            let key = SessionKey(day: day, title: sessionTitle)
            var accumulator = grouped[key] ?? SessionAccumulator(date: date, title: sessionTitle)

            let weight = weightColumn.flatMap { parseNumber(table.value(row, at: $0)) }
            let reps = repsColumn.flatMap { parseInteger(table.value(row, at: $0)) }
            let duration = durationColumn.flatMap { parseDuration(table.value(row, at: $0)) }
            let distance = distanceColumn.flatMap { parseNumber(table.value(row, at: $0)) }
            let effort = rpeColumn.flatMap { parseNumber(table.value(row, at: $0)) }
                .flatMap { TrainingEffortRating(scale: .rpe, value: $0) }
            guard weight != nil || reps != nil || duration != nil || distance != nil else {
                skipped += 1
                continue
            }
            var completed = NativeWorkoutSet(index: accumulator.setCount(for: exercise.id),
                                               weightKg: weight, reps: reps,
                                               durationS: duration, distanceM: distance,
                                               effort: effort)
            completed.isCompleted = true
            accumulator.append(completed, exerciseId: exercise.id)
            if let notesColumn {
                let note = table.value(row, at: notesColumn).trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { accumulator.notes.append(note) }
            }
            grouped[key] = accumulator
        }

        let source: TrainingRecordSource = {
            switch format {
            case .fitNotes: return .fitNotes
            case .strong: return .strong
            case .automatic:
                return table.column(named: ["category"]) != nil ? .fitNotes : .strong
            }
        }()
        let workouts = grouped.values.compactMap { $0.workout(source: source) }
            .sorted { $0.startedAt > $1.startedAt }
        guard !workouts.isEmpty else { throw TrainingExchangeError.noUsableRows }
        return TrainingHistoryImport(exercises: Array(importedById.values).sorted { $0.title < $1.title },
                                     workouts: workouts, skippedRows: skipped)
    }

    private struct SessionKey: Hashable { let day: String; let title: String }

    private struct SessionAccumulator {
        let date: Date
        let title: String
        var exerciseOrder: [String] = []
        var setsByExercise: [String: [NativeWorkoutSet]] = [:]
        var notes: [String] = []

        func setCount(for exerciseId: String) -> Int { setsByExercise[exerciseId]?.count ?? 0 }

        mutating func append(_ set: NativeWorkoutSet, exerciseId: String) {
            if setsByExercise[exerciseId] == nil { exerciseOrder.append(exerciseId) }
            setsByExercise[exerciseId, default: []].append(set)
        }

        func workout(source: TrainingRecordSource) -> NativeWorkout? {
            let exercises = exerciseOrder.compactMap { id -> NativeWorkoutExercise? in
                guard let sets = setsByExercise[id], !sets.isEmpty else { return nil }
                return NativeWorkoutExercise(exerciseId: id, sets: sets)
            }
            guard !exercises.isEmpty else { return nil }
            let start = Int(date.timeIntervalSince1970)
            let measuredSeconds = exercises.flatMap(\.sets).compactMap(\.durationS).reduce(0, +)
            let conservativeDuration = max(60, measuredSeconds > 0 ? measuredSeconds : exercises.flatMap(\.sets).count * 90)
            let note = Array(Set(notes)).sorted().joined(separator: " · ")
            return NativeWorkout(id: deterministicUUID("\(start)|\(title)|\(source.rawValue)"),
                                 title: title, startedAt: start, endedAt: start + conservativeDuration,
                                 plannedDay: dayFormatter.string(from: date), routineIds: [],
                                 exercises: exercises, tracker: nil,
                                 note: note.isEmpty ? nil : note, source: source)
        }
    }

    private struct CSVTable {
        let headers: [String]
        let rows: [[String]]

        init(_ text: String) {
            let parsed = CSVTable.parse(text)
            headers = parsed.first?.map(Self.normalizeHeader) ?? []
            rows = Array(parsed.dropFirst())
        }

        func column(named choices: [String]) -> Int? {
            choices.lazy.compactMap { choice in headers.firstIndex(of: Self.normalizeHeader(choice)) }.first
        }

        func value(_ row: [String], at index: Int) -> String { row.indices.contains(index) ? row[index] : "" }

        private static func normalizeHeader(_ value: String) -> String {
            value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)
                .map(String.init).joined()
        }

        private static func parse(_ text: String) -> [[String]] {
            var rows: [[String]] = []
            var row: [String] = []
            var field = ""
            var quoted = false
            let values = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
            var index = 0
            while index < values.count {
                let character = values[index]
                if character == "\"" {
                    if quoted, index + 1 < values.count, values[index + 1] == "\"" {
                        field.append("\""); index += 1
                    } else { quoted.toggle() }
                } else if character == ",", !quoted {
                    row.append(field); field = ""
                } else if character == "\n", !quoted {
                    row.append(field); field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                } else { field.append(character) }
                index += 1
            }
            row.append(field)
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            return rows
        }
    }

    private static let dayFormatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian); value.dateFormat = "yyyy-MM-dd"
        return value
    }()

    private static let dateFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        "dd.MM.yyyy HH:mm", "dd.MM.yyyy", "MM/dd/yyyy HH:mm", "MM/dd/yyyy"
    ].map { format in
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian); value.dateFormat = format
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = ISO8601DateFormatter().date(from: trimmed) { return iso }
        return dateFormatters.lazy.compactMap { $0.date(from: trimmed) }.first
    }

    private static func parseNumber(_ value: String) -> Double? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalized).flatMap { $0.isFinite ? $0 : nil }
    }

    private static func parseInteger(_ value: String) -> Int? {
        parseNumber(value).map { Int($0.rounded()) }
    }

    private static func parseDuration(_ value: String) -> Int? {
        if let seconds = parseInteger(value) { return max(0, seconds) }
        let lower = value.lowercased()
        let numbers = lower.split { !$0.isNumber }.compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        if lower.contains("h") { return numbers[0] * 3_600 + (numbers.count > 1 ? numbers[1] * 60 : 0) }
        if lower.contains(":") {
            return numbers.count >= 3 ? numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]
                : numbers.count == 2 ? numbers[0] * 60 + numbers[1] : numbers[0]
        }
        return numbers[0]
    }

    private static func normalizeName(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined()
    }

    private static func stableSlug(_ value: String) -> String {
        let slug = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined().split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return slug.isEmpty ? UUID().uuidString.lowercased() : slug
    }

    private static func deterministicUUID(_ value: String) -> UUID {
        var a: UInt64 = 0xcbf29ce484222325
        var b: UInt64 = 0x84222325cbf29ce4
        for byte in value.utf8 {
            a = (a ^ UInt64(byte)) &* 0x100000001b3
            b = (b ^ UInt64(byte &+ 31)) &* 0x100000001b3
        }
        let hex = String(format: "%016llx%016llx", a, b)
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }
}

/// Conservative byte estimate for the normalized rows. It is used as a release guard, not shown as
/// a precision claim. Media never contributes because completed workouts retain only a short media id.
public enum TrainingStorageBudget {
    public static let twentyYearTargetBytes = 150 * 1_024 * 1_024

    public static func estimatedHistoryBytes(workoutsPerWeek: Int = 5,
                                             exercisesPerWorkout: Int = 7,
                                             setsPerExercise: Int = 4,
                                             years: Int = 20) -> Int {
        let workouts = max(0, workoutsPerWeek) * 52 * max(0, years)
        let exercises = workouts * max(0, exercisesPerWorkout)
        let sets = exercises * max(0, setsPerExercise)
        return workouts * 260 + exercises * 210 + sets * 150
    }
}
