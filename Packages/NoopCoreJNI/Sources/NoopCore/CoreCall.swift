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
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
        func string(_ k: String) -> String { args[k] as? String ?? "" }
        func int(_ k: String, _ fallback: Int) -> Int { (args[k] as? NSNumber)?.intValue ?? fallback }
        func ok(_ done: Bool) -> String { done ? #"{"ok":true}"# : #"{"ok":false}"# }
        switch op {
        case "media.configure":
            guard let root = args["root"] as? String, root.hasPrefix("/") else { return #"{"error":"mediaRootMissing"}"# }
            return CoreRead.json(await CoreExerciseMedia.shared.configure(root: URL(fileURLWithPath: root), disabled: args["disabled"] as? Bool ?? false))
        case "media.info": return CoreRead.json(await CoreExerciseMedia.shared.info())
        case "media.install":
            return CoreRead.json(await CoreExerciseMedia.shared.install(archive: URL(fileURLWithPath: string("archive"))))
        case "media.cancel": await CoreExerciseMedia.shared.cancel(); return ok(true)
        case "media.disabled": await CoreExerciseMedia.shared.setDisabled(args["disabled"] as? Bool ?? false); return ok(true)
        case "media.delete": return ok(await CoreExerciseMedia.shared.delete())
        case "provider.defaults": return CoreRead.json(CoreExerciseProvider.Defaults())
        case "provider.invalidate": await CoreExerciseProvider.shared.invalidate(); return ok(true)
        case "hevy.verify":
            do { try await CoreHevyClient(key: string("key")).verify(); return ok(true) }
            catch let error as HevyImportError { return CoreRead.json(["error": error.rawValue]) }
            catch { return #"{"error":"network"}"# }
        case "hevy.syncStatus": return CoreRead.json(await CoreHevy.shared.read())
        case "hevy.cancelSync": return CoreRead.json(await CoreHevy.shared.cancel(id: string("id")))
        case "hevy.stopSync":
            await CoreHevy.shared.cancelAndWait()
            await CoreHevyRoutines.shared.invalidate()
            return ok(true)
        default: break
        }
        guard let (store, _) = ShadowSession.storeAndPath, let reader = ShadowSession.reader else {
            return #"{"error":"noStore"}"#
        }
        switch op {
        case "hevy.startSync": return CoreRead.json(await CoreHevy.shared.start(store: store, key: string("key"), routinesOnly: args["routinesOnly"] as? Bool ?? false))
        case "hevy.info":
            do { return CoreRead.json(["storedWorkouts": try await store.hevyWorkoutCount()]) }
            catch { return #"{"error":"storeUnavailable"}"# }
        case "hevy.resetSync":
            await CoreHevy.shared.cancelAndWait()
            await CoreHevyRoutines.shared.invalidate()
            do { try await store.resetHevySyncState(); return ok(true) }
            catch { return #"{"error":"storeUnavailable"}"# }
        case "hevy.routines":
            do { return CoreRead.json(try await CoreHevyRoutines.shared.preview(store: store, restSeconds: int("restSeconds", 120))) }
            catch { return #"{"error":"routinesUnavailable"}"# }
        case "hevy.importRoutines":
            return ok((try? await CoreHevyRoutines.shared.accept(store: store, token: string("token"), ids: args["ids"] as? [String] ?? [])) ?? false)
        case "hevy.forget":
            await CoreHevy.shared.cancelAndWait()
            await CoreHevyRoutines.shared.invalidate()
            do { try await store.deleteAllHevyData(); return ok(true) }
            catch { return #"{"error":"storeUnavailable"}"# }
        case "training.sessionReminders":
            return CoreRead.json(await SessionRatingReminders.candidates(reader: reader,
                prompt: SessionRatingPrompt(rawValue: string("prompt")) ?? .whenUseful,
                maxHR: (args["maxHR"] as? NSNumber)?.doubleValue,
                dismissed: args["dismissedWorkouts"] as? [String] ?? [],
                forDelivery: args["forDelivery"] as? Bool ?? false))
        case "training.exerciseMedia":
            let exercise = (try? await store.trainingExercises())?.first { $0.id == string("id") }
            guard let mediaId = exercise?.mediaId,
                  let path = await CoreExerciseMedia.shared.resolve(mediaId: mediaId, still: args["still"] as? Bool ?? false)
            else { return #"{"available":false}"# }
            return CoreRead.json(CoreExerciseMedia.Resolved(path: path))
        case "provider.preview":
            do { return CoreRead.json(try await CoreExerciseProvider.shared.preview(store: store,
                endpoint: string("endpoint"), key: args["key"] as? String, header: args["header"] as? String)) }
            catch is CancellationError { return #"{"error":"cancelled"}"# }
            catch let error as ExerciseDBProviderError { return CoreRead.json(["error": error.rawValue]) }
            catch { return #"{"error":"invalidResponse"}"# }
        case "provider.accept":
            return ok((try? await CoreExerciseProvider.shared.accept(store: store, requested: string("token"),
                ids: args["ids"] as? [String] ?? [])) ?? false)
        case "goals.snapshot", "goals.setup":
            let settings = CoreGoals.Settings(profileSex: string("sex"),
                lastSync: (args["lastSync"] as? NSNumber).flatMap { $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil },
                agelessEnabled: args["ageless"] as? Bool ?? false,
                dismissedWorkoutSpans: args["dismissedWorkouts"] as? [String] ?? [])
            do {
                return op == "goals.snapshot"
                    ? CoreRead.json(try await CoreGoals.snapshot(reader: reader, settings: settings))
                    : CoreRead.json(try await CoreGoals.setup(reader: reader, settings: settings))
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "goals.addPeriod":
            return CoreRead.json(await CoreGoals.addPeriodGoal(store: store, metric: string("metric"),
                period: string("period"), target: (args["target"] as? NSNumber)?.doubleValue ?? 0,
                threshold: (args["threshold"] as? NSNumber)?.doubleValue))
        case "goals.changePeriod":
            return CoreRead.json(await CoreGoals.changePeriodGoal(store: store, id: string("id"), action: string("action"),
                target: (args["target"] as? NSNumber)?.doubleValue, reason: args["reason"] as? String))
        case "goals.saveDaily":
            return CoreRead.json(await CoreGoals.saveDaily(store: store, slot: string("slot"),
                value: (args["value"] as? NSNumber)?.doubleValue ?? 0, runs: string("runs"),
                endsOn: args["endsOn"] as? String, weekdays: (args["weekdays"] as? [NSNumber])?.map(\.intValue) ?? Array(1...7),
                showsAsRing: args["showsAsRing"] as? Bool ?? true))
        case "goals.turnOffDaily":
            return CoreRead.json(await CoreGoals.turnOffDaily(store: store, slot: string("slot")))
        case "goals.catalog", "goals.ltDraft", "goals.ltCreate":
            let settings = CoreGoals.Settings(profileSex: string("sex"),
                lastSync: (args["lastSync"] as? NSNumber).flatMap { $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil },
                agelessEnabled: args["ageless"] as? Bool ?? false,
                dismissedWorkoutSpans: args["dismissedWorkouts"] as? [String] ?? [])
            let weight = (args["profileWeightKg"] as? NSNumber)?.doubleValue ?? 0
            let state = (args["state"] as? String).flatMap {
                try? JSONDecoder().decode(CoreLongTermGoals.State.self, from: Data($0.utf8))
            } ?? CoreLongTermGoals.State()
            do {
                switch op {
                case "goals.catalog":
                    return CoreRead.json(try await CoreLongTermGoals.catalog(reader: reader, settings: settings,
                                                                             profileWeightKg: weight))
                case "goals.ltDraft":
                    return CoreRead.json(try await CoreLongTermGoals.draft(reader: reader, settings: settings,
                        profileWeightKg: weight, state: state, action: string("action")))
                default:
                    return CoreRead.json(await CoreLongTermGoals.create(reader: reader, settings: settings,
                        profileWeightKg: weight, state: state, replacing: args["replacing"] as? String,
                        keepBoth: args["keepBoth"] as? Bool ?? false, riskReason: args["riskReason"] as? String))
                }
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "goals.changeLongTerm":
            return CoreRead.json(await CoreLongTermGoals.change(store: store, id: string("id"), action: string("action"),
                                                                reason: args["reason"] as? String))
        case "goals.toggleAction":
            return CoreRead.json(await CoreGoals.toggleAction(store: store, actionId: string("actionId"), day: string("day")))
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
        case "training.history":
            return CoreRead.json(await CoreTrainingHistory.read(reader: reader, span: string("span"),
                jumpDay: args["jumpDay"] as? String, lifts: args["lifts"] as? [String] ?? [],
                maxHR: (args["maxHR"] as? NSNumber)?.doubleValue ?? Double(StrainScorer.defaultMaxHR()),
                sex: string("sex"), dismissedWorkouts: args["dismissedWorkouts"] as? [String] ?? []))
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
        case "training.sessionDetail":
            let maxHR = (args["maxHR"] as? NSNumber)?.doubleValue ?? Double(StrainScorer.defaultMaxHR())
            let edges = (args["zoneBpmEdges"] as? [NSNumber])?.map(\.doubleValue)
            let zones = edges.map { HRZones.zones(bpmEdges: $0, maxHR: maxHR) } ?? HRZones.zones(maxHR: maxHR)
            return CoreRead.json(await CoreTrainingSession.read(reader: reader, id: string("id"), zoneSet: zones,
                dismissed: args["dismissedWorkouts"] as? [String] ?? []))
        case "training.sessionRating":
            return ok(await CoreTrainingSession.rate(reader: reader, id: string("id"),
                rpe: (args["rpe"] as? NSNumber)?.doubleValue, remove: args["remove"] as? Bool ?? false,
                dismissed: args["dismissedWorkouts"] as? [String] ?? []))
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
            guard let library = try? await CoreTrainingLibrary.catalog(store: store, availableEquipment: Set(args["availableEquipment"] as? [String] ?? [])) else { return #"{"error":"libraryUnavailable"}"# }
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
        case "training.importLifting":
            guard string("data").utf8.count <= (LiftingHistoryImport.maximumBytes + 2) / 3 * 4,
                  let zone = TimeZone(identifier: string("timeZone")),
                  let data = Data(base64Encoded: string("data")), data.count <= LiftingHistoryImport.maximumBytes else {
                return #"{"error":"invalidImport"}"#
            }
            do {
                let imported = try await LiftingHistoryImport.run(data: data, store: store, zone: zone)
                struct ImportResult: Encodable {
                    let sessions: Int, skipped: Int
                    let workouts: [WorkoutRow]
                }
                return CoreRead.json(ImportResult(sessions: imported.sessionCount, skipped: imported.skipped,
                    workouts: LiftingHistoryImport.workoutRows(imported)))
            } catch LiftingHistoryImport.ImportError.noWorkouts {
                return #"{"error":"noWorkouts"}"#
            } catch { return #"{"error":"importFailed"}"# }
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
