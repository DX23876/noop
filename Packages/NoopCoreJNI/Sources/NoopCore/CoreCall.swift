import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopProtocol
import WhoopStore

/// One door for the Android screens into the shared code (Android parity plan 1.2): an operation name and its
/// arguments as a JSON object in, a JSON answer out, so a new screen adds an operation here instead of a JNI
/// function. Runs against the store the shadow session opened; `{"error": …}` when there is none.
public enum CoreCall {
    public static func run(_ op: String, _ argsJSON: String) async -> String {
        if op == "core.setResources" {
            // Validate the protocol asset before any notification can reach the collector. Android has no
            // SwiftPM bundle; asking Bundle.module on the first bonded event otherwise terminates the app.
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
            guard let dir = args["dir"] as? String else { return #"{"error":"resourceDirectoryMissing"}"# }
            let directory = URL(fileURLWithPath: dir)
            do {
                try installSchema(from: directory.appendingPathComponent("whoop_protocol.json"))
                BundledExerciseCatalog.resourceDirectory = directory
                return #"{"ok":true}"#
            } catch {
                return #"{"error":"protocolSchemaUnavailable"}"#
            }
        }
        guard let (store, _) = ShadowSession.storeAndPath, let reader = ShadowSession.reader else {
            return #"{"error":"noStore"}"#
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
        func string(_ k: String) -> String { args[k] as? String ?? "" }
        func int(_ k: String, _ fallback: Int) -> Int { (args[k] as? NSNumber)?.intValue ?? fallback }
        func ok(_ done: Bool) -> String { done ? #"{"ok":true}"# : #"{"ok":false}"# }
        switch op {
        case "training.snapshot":
            let start = TrainingWeekStart(rawValue: args["weekStartsOn"] as? String ?? "") ?? .monday
            let dismissed = args["dismissedWorkouts"] as? [String] ?? []
            return CoreRead.json(await CoreTraining.snapshot(reader: reader, days: int("days", 4_000),
                                                             weekStartsOn: start, dismissedWorkoutSpans: dismissed))
        case "training.saveRoutine": return ok(await CoreTraining.saveRoutine(store: store, json: string("routine")))
        case "training.createRoutine":
            return ok(await CoreTraining.createRoutine(store: store, id: args["id"] as? String, title: string("title"),
                                                       exerciseIds: args["exerciseIds"] as? [String] ?? [],
                                                       weekdays: args["weekdays"] as? [Int]))
        case "training.duplicateRoutine":
            return ok(await CoreTraining.duplicateRoutine(store: store, id: string("id"), title: string("title")))
        case "training.load":
            let maxHR = (args["maxHR"] as? NSNumber)?.doubleValue ?? Double(StrainScorer.defaultMaxHR())
            return CoreRead.json(await CoreTrainingLoad.read(reader: reader, maxHR: maxHR, sex: string("sex"),
                                                             dismissedWorkoutSpans: args["dismissedWorkouts"] as? [String] ?? []))
        case "training.strength":
            return CoreRead.json(await CoreTrainingReports.strength(reader: reader, days: int("days", 120),
                weekOffset: int("weekOffset", 0), exerciseId: args["exerciseId"] as? String,
                firstWeekday: int("firstWeekday", 2), dismissedWorkouts: args["dismissedWorkouts"] as? [String] ?? []))
        case "training.cardio":
            let maxHR = (args["maxHR"] as? NSNumber)?.doubleValue ?? Double(StrainScorer.defaultMaxHR())
            let edges = (args["zoneBpmEdges"] as? [NSNumber])?.map(\.doubleValue)
            let zones = edges.map { HRZones.zones(bpmEdges: $0, maxHR: maxHR) } ?? HRZones.zones(maxHR: maxHR)
            return CoreRead.json(await CoreTrainingReports.cardio(reader: reader, maxHR: maxHR, sex: string("sex"),
                days: int("days", 120), weekOffset: int("weekOffset", 0), sport: args["sport"] as? String,
                zoneSet: zones, dismissedWorkouts: args["dismissedWorkouts"] as? [String] ?? []))
        case "training.strengthSession":
            return CoreRead.json(await CoreTrainingReports.session(reader: reader, id: string("id")))
        case "training.saveStrengthDetails":
            return CoreRead.json(["result": await CoreTrainingReports.saveDetails(reader: reader,
                sessionId: string("sessionId"), drafts: args["drafts"] as? [[String: Any]] ?? [],
                dismissedWorkouts: args["dismissedWorkouts"] as? [String] ?? [])])
        case "training.mapStrengthExercise":
            return ok(await CoreTrainingReports.saveMapping(store: store, title: string("title"),
                primary: string("primary"), secondary: args["secondary"] as? [String] ?? []))
        case "training.muscleFeedback":
            return ok(await CoreTrainingReports.recordFeedback(store: store, muscle: string("muscle"),
                feeling: int("feeling", -1)))
        case "training.library":
            guard let library = try? await CoreTrainingLibrary.catalog(store: store) else { return #"{"error":"libraryUnavailable"}"# }
            return CoreRead.json(library)
        case "training.exerciseDetail":
            return CoreRead.json(await CoreTrainingLibrary.detail(reader: reader, id: string("id"),
                dismissedWorkouts: args["dismissedWorkouts"] as? [String] ?? []))
        case "training.createExercise":
            let id = await CoreTrainingLibrary.create(store: store, title: string("title"), mode: string("mode"),
                primary: string("primary"), equipment: string("equipment"), instruction: string("instruction"),
                unilateral: args["unilateral"] as? Bool ?? false)
            return id.map { CoreRead.json(["id": $0]) } ?? #"{"error":"exerciseNotSaved"}"#
        case "training.importCatalog":
            let count = await CoreTrainingLibrary.importCatalog(store: store, json: string("archive"))
            return count.map { CoreRead.json(["count": $0]) } ?? #"{"error":"catalogNotImported"}"#
        case "training.starters": return CoreRead.json(await CoreTraining.starters(store: store))
        case "training.addStarter": return ok(await CoreTraining.addStarter(store: store, index: int("index", -1)))
        case "training.setSchedule":
            return ok(await CoreTraining.setSchedule(store: store, days: args["days"] as? [String: [String]] ?? [:]))
        case "training.deleteRoutine": return ok(await CoreTraining.deleteRoutine(store: store, id: string("id")))
        case "training.saveSchedule": return ok(await CoreTraining.saveSchedule(store: store, json: string("schedule")))
        case "training.saveExercise": return ok(await CoreTraining.saveExercise(store: store, json: string("exercise")))
        case "training.saveDraft": return ok(await CoreTraining.saveDraft(store: store, json: string("draft")))
        case "training.discardDraft": return ok(await CoreTraining.discardDraft(store: store, id: string("id")))
        case "training.finishWorkout": return ok(await CoreTraining.finishWorkout(store: store, json: string("workout")))
        case "training.startDraft":
            let ids = args["routineIds"] as? [String] ?? []
            let dismissed = args["dismissedWorkouts"] as? [String] ?? []
            return CoreRead.json(await CoreTraining.startDraft(reader: reader, routineIds: ids,
                                                               dismissedWorkoutSpans: dismissed))
        case "training.changeDraft":
            return CoreRead.json(await CoreTraining.changeDraft(store: store, args: args))
        case "training.finishDraft":
            let rpe = (args["sessionRPE"] as? NSNumber)?.doubleValue
            return CoreRead.json(await CoreTraining.finishDraft(store: store, sessionRPE: rpe))
        default:
            return #"{"error":"unknownOp"}"#
        }
    }
}
