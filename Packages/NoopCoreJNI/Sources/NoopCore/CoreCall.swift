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
        // Whatever the shared code wrote to UserDefaults during the call reaches the disk (`CoreDefaults`).
        defer { CoreDefaults.save() }
        return await perform(op, argsJSON)
    }

    private static func perform(_ op: String, _ argsJSON: String) async -> String {
        if op == "training.plates" {
            // The plate calculator's loading per side (`PlateCalculator`); null below the bar weight.
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
            let plates = (args["platesKg"] as? [NSNumber])?.map(\.doubleValue) ?? []
            guard let total = (args["totalKg"] as? NSNumber)?.doubleValue, let bar = (args["barKg"] as? NSNumber)?.doubleValue,
                  let loading = PlateCalculator.loading(totalKg: total, barKg: bar, availablePairsKg: plates) else { return "null" }
            struct Wire: Encodable { let platesPerSideKg: [Double]; let achievableTotalKg: Double; let remainderKg: Double }
            return CoreRead.json(Wire(platesPerSideKg: loading.platesPerSideKg,
                                      achievableTotalKg: loading.achievableTotalKg, remainderKg: loading.remainderKg))
        }
        if op == "tile.delta" {
            // A Today measure tile's change against the wearer's usual and its colour (`MeasureTileReading`).
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
            let key = args["key"] as? String ?? ""
            let values = (args["values"] as? [NSNumber])?.map(\.doubleValue) ?? []
            struct Wire: Encodable { let delta: String?; let tone: String?; let summary: MeasureTileReading.Summary? }
            return CoreRead.json(Wire(delta: MeasureTileReading.delta(key: key, values: values),
                                      tone: MeasureTileReading.tone(key: key, values: values)?.rawValue,
                                      summary: MeasureTileReading.summary(key: key, values: values)))
        }
        if op == "tile.facts" {
            // What a measure tile knows about itself beyond today's figure (`MeasureFacts`), so the week is
            // averaged once for both phones rather than once per platform.
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
            let days = (args["days"] as? [String]) ?? []
            let values = (args["values"] as? [NSNumber])?.map(\.doubleValue) ?? []
            let points = zip(days, values).map { MeasureFacts.Point(day: $0, value: $1) }
            let key = args["key"] as? String ?? ""
            let facts = MeasureFacts.read(points: points,
                                          today: args["today"] as? String ?? LogicalDay.key(Date()),
                                          target: (args["target"] as? NSNumber)?.doubleValue
                                              ?? MeasureFacts.storedTarget(forKey: key),
                                          direction: MeasureFacts.direction(forKey: key))
            // Formatted here as well as computed here: a figure rounded once on each phone is a figure
            // that can read differently on the two, which is the thing this whole reading exists to stop.
            func text(_ value: Double?) -> String? {
                value.map { MeasureTileReading.figure(key: key, value: $0) }
            }
            struct Wire: Encodable {
                let today: Double?, weekAverage: Double?, weekTotal: Double?
                let lastValue: Double?, lastValueText: String?, lastDay: String?, daysSinceLast: Int?
                let weekChange: Double?, quarterChange: Double?, target: Double?, targetLeft: Double?
                let todayText: String?, weekAverageText: String?, weekTotalText: String?
                let weekChangeText: String?, quarterChangeText: String?, targetLeftText: String?
                let best: Double?, bestDay: String?, bestText: String?
                let daysAboveTarget: Int?, weekDaysWithEntry: Int, daysWithEntry: Int
                let aboveUsualRecently: Int?
                /// What the row-wide form puts under its chart, chosen and formatted in one place so both
                /// phones say the same things in the same order (`MeasureFacts.strip`).
                let strip: [MeasureFacts.StripEntry]
            }
            return CoreRead.json(Wire(today: facts.today, weekAverage: facts.weekAverage, weekTotal: facts.weekTotal,
                                      lastValue: facts.lastValue, lastValueText: text(facts.lastValue),
                                      lastDay: facts.lastDay,
                                      daysSinceLast: facts.daysSinceLast, weekChange: facts.weekChange,
                                      quarterChange: facts.quarterChange,
                                      target: facts.target, targetLeft: facts.targetLeft,
                                      todayText: text(facts.today), weekAverageText: text(facts.weekAverage),
                                      weekTotalText: text(facts.weekTotal),
                                      weekChangeText: text(facts.weekChange.map(abs)),
                                      quarterChangeText: text(facts.quarterChange.map(abs)),
                                      targetLeftText: text(facts.targetLeft),
                                      best: facts.best, bestDay: facts.bestDay, bestText: text(facts.best),
                                      daysAboveTarget: facts.daysAboveTarget,
                                      weekDaysWithEntry: facts.weekDaysWithEntry,
                                      daysWithEntry: facts.daysWithEntry,
                                      aboveUsualRecently: facts.aboveUsualRecently,
                                      strip: MeasureFacts.strip(key: key, facts: facts, values: values)))
        }
        if op == "momentum.day" {
            return CoreRead.json(["day": LogicalDay.key(Date())])
        }
        if op == "ble.strapChoice" {
            // Which strap a scan may take while the WHOOP entry names none (`StrapClaim`). Pure: the host
            // collects the advertisements and holds the timer, the rule lives in one place for both apps.
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
            let heard = (args["heard"] as? [[String: Any]])?.map {
                HeardStrap(address: $0["address"] as? String ?? "", name: $0["name"] as? String,
                           rssi: ($0["rssi"] as? NSNumber)?.intValue ?? 0)
            } ?? []
            let choice = StrapClaim.choose(heard: heard.filter { !$0.address.isEmpty },
                                           claimed: args["claimed"] as? String)
            struct Wire: Encodable { let verdict: String; let address: String?; let choices: [HeardStrap] }
            return CoreRead.json(Wire(verdict: choice.verdict.rawValue, address: choice.address,
                                      choices: choice.choices))
        }
        if op == "core.setResources" {
            // Validate the protocol asset before any notification can reach the collector. Android has no
            // SwiftPM bundle; asking Bundle.module on the first bonded event otherwise terminates the app.
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
            guard let dir = args["dir"] as? String else { return #"{"error":"resourceDirectoryMissing"}"# }
            // Foundation finds Application Support and UserDefaults' file under HOME, which an Android app process
            // lacks; the coach keeps its conversations and settings there.
            if let home = args["home"] as? String, !home.isEmpty {
                setenv("HOME", home, 1)
                setenv("XDG_DATA_HOME", home + "/share", 1)
                setenv("XDG_CONFIG_HOME", home + "/config", 1)
                // Foundation does not create the folder its UserDefaults file goes in, and drops every write
                // without one; and a store made before HOME was set would keep its old path.
                for dir in ["/share", "/config"] {
                    try? FileManager.default.createDirectory(atPath: home + dir, withIntermediateDirectories: true)
                }
                CoreDefaults.load(from: URL(fileURLWithPath: home + "/config/defaults.plist"))
            }
            let directory = URL(fileURLWithPath: dir)
            do {
                try installSchema(from: directory.appendingPathComponent("whoop_protocol.json"))
                BundledExerciseCatalog.resourceDirectory = directory
                FoodCatalog.resourceDirectory = directory
                // The wearer's language for the text the shared code writes; none keeps the English source.
                CoreLocalization.load((args["l10n"] as? String).map { URL(fileURLWithPath: $0) })
                return #"{"ok":true}"#
            } catch {
                return #"{"error":"protocolSchemaUnavailable"}"#
            }
        }
        if op == "shadow.devices" {
            // The active strap and every registered WHOOP (archived ones too), from Android's device registry;
            // without "registered" only the active strap moves.
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
            ShadowSession.setDevices(activeDeviceId: args["active"] as? String ?? "",
                                     registeredWhoopIds: args["registered"] as? [String])
            return #"{"ok":true}"#
        }
        if op == "core.setLanguage" {
            // A language picked in Settings, applied without a restart.
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
            CoreLocalization.load((args["l10n"] as? String).map { URL(fileURLWithPath: $0) })
            return #"{"ok":true}"#
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
        if op.hasPrefix("math."), let answer = CoreMath.run(op, args) { return answer }
        if op.hasPrefix("workout.voice."), let answer = CoreWorkoutVoice.run(op, args) { return answer }
        // The Roadmap page needs no store and no session: it reads two files from the repository.
        if op.hasPrefix("project."), let answer = await CoreProject.run(op, args) { return answer }
        if op.hasPrefix("donation."), let answer = await CoreDonation.run(op, args) { return answer }
        func string(_ k: String) -> String { args[k] as? String ?? "" }
        func int(_ k: String, _ fallback: Int) -> Int { (args[k] as? NSNumber)?.intValue ?? fallback }
        func ok(_ done: Bool) -> String { done ? #"{"ok":true}"# : #"{"ok":false}"# }
        switch op {
        case "device.deleteData":
            // "Delete this device's data" and "Forget": the core's copy goes first, as `DeviceRegistry.forget`
            // does on Apple, so a failure leaves both stores holding the device.
            let id = string("id")
            guard !id.isEmpty else { return #"{"error":"invalid"}"# }
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            do { try await store.deleteAllData(deviceId: id); return #"{"ok":true}"# }
            catch { return #"{"error":"deleteFailed"}"# }
        case "sleep.restage":
            // A night the wearer added or edited, staged from the strap's raw streams with the wearer's stager,
            // as the Apple apps do (`EditedSleepHeal.restage`); null when the window has too little raw data.
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            let method = SleepStager.Method(rawValue: string("method")) ?? .v2
            let stages = await EditedSleepHeal.restage(
                store: store, deviceId: string("deviceId"), start: int("start", 0), end: int("end", 0),
                staging: .init(method: method, motionAwareWake: args["motionAwareWake"] as? Bool ?? false))
            return CoreRead.json(["stages": stages])
        case "sleep.addSeed":
            // Where the "add a sleep" pickers open, by the one rule both platforms use.
            let seed = ManualSleepPlan.seed(
                dayStart: Date(timeIntervalSince1970: TimeInterval(int("dayStart", Int(Date().timeIntervalSince1970)))),
                hasMainSleep: args["hasMainSleep"] as? Bool ?? false,
                now: Date(timeIntervalSince1970: TimeInterval(int("now", Int(Date().timeIntervalSince1970)))))
            return CoreRead.json(["start": "\(seed.start)", "end": "\(seed.end)"])
        case "sleep.addPreflight":
            // What adding a sleep by hand over [start, end] would do, decided by `ManualSleepPlan`, which
            // the Apple side asks the same question. Android reads the rows through here rather than
            // keeping its own copy of the rule.
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            let start = int("start", 0), end = int("end", 0)
            let now = int("now", Int(Date().timeIntervalSince1970))
            let computedId = string("computedDeviceId")
            let rows = (try? await store.sleepSessions(deviceId: computedId,
                                                       from: start - 86_400, to: end + 86_400, limit: 200)) ?? []
            let method = SleepStager.Method(rawValue: string("method")) ?? .v2
            let staged = await EditedSleepHeal.restage(
                store: store, deviceId: string("deviceId"), start: start, end: end,
                staging: .init(method: method, motionAwareWake: args["motionAwareWake"] as? Bool ?? false))
            let outcome = ManualSleepPlan.decide(
                start: start, end: end, now: now,
                existing: rows.map { SleepEditGuard.Span(start: $0.effectiveStartTs, end: $0.endTs) },
                hasRawData: staged != nil)
            switch outcome {
            case .ok: return CoreRead.json(["outcome": "ok"])
            case .noRawData: return CoreRead.json(["outcome": "noRawData"])
            case .invalidWindow: return CoreRead.json(["outcome": "invalidWindow"])
            case .blocked(let s, let e):
                return CoreRead.json(["outcome": "blocked", "start": "\(s)", "end": "\(e)"])
            }
        case "nap.evaluate":
            // Android's nap review card (CORE-ONLY-PLAN, decision 6): the core's NapDetector over the strap's
            // gravity and heart rate in [from, to], with the wearer's settings.
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            let id = string("deviceId"), from = int("from", 0), to = int("to", 0)
            let gravity = (try? await store.gravitySamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? []
            let hr = (try? await store.hrSamples(deviceId: id, from: from, to: to, limit: 200_000)) ?? []
            let config = NapDetector.Config(
                enabled: args["enabled"] as? Bool ?? false, minNapMinutes: int("minNapMinutes", 20),
                maxNapMinutes: int("maxNapMinutes", 90),
                stillThresholdG: (args["stillThresholdG"] as? NSNumber)?.doubleValue ?? 0.08,
                hrSettleMarginBpm: int("hrSettleMarginBpm", 8),
                smoothWindowSeconds: (args["smoothWindowSeconds"] as? NSNumber)?.doubleValue ?? 120)
            let resting = (args["restingHr"] as? NSNumber)?.intValue
            let d = NapDetector.evaluate(gravity: gravity, hr: hr, restingHr: resting, config: config)
            struct Wire: Encodable {
                let verdict: String; let gravityRows: Int
                let start: Int?; let end: Int?; let meanHr: Int?; let confidence: Double?
            }
            return CoreRead.json(Wire(verdict: d.verdict.rawValue, gravityRows: gravity.count,
                                      start: d.candidate?.start, end: d.candidate?.end,
                                      meanHr: d.candidate?.meanHr, confidence: d.candidate?.confidence))
        case "import.file":
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            return await CoreImport.run(kind: string("kind"), path: string("path"), deviceId: string("deviceId"), store: store)
        case "sql.query": return await CoreSql.query(args)
        case "sql.exec": return await CoreSql.exec(args)
        case "store.adoptRoom":
            // Android without Room (CORE-ONLY-PLAN): a live install's Room file, copied into the core once. The
            // tombstone tables merge into the defaults lists the shared code reads.
            let path = string("path")
            guard path.hasPrefix("/") else { return #"{"error":"invalid"}"# }
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            do {
                let report = try await store.adoptRoomStore(atPath: path)
                CoreBackup.applyTombstones(report, replacing: false)
                struct Wire: Encodable { let ok: Bool; let roomVersion: Int?; let copied: [String: Int]; let skipped: [String: String] }
                return CoreRead.json(Wire(ok: true, roomVersion: report.roomVersion, copied: report.copiedRows,
                                          skipped: report.skipped))
            } catch RoomStoreAdoption.AdoptionError.notRoom {
                return #"{"error":"notRoom"}"#
            } catch {
                return CoreRead.json(["error": "adoptFailed", "detail": error.localizedDescription])
            }
        case "device.reKey":
            let from = string("from"), to = string("to")
            guard !from.isEmpty, !to.isEmpty else { return #"{"error":"invalid"}"# }
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            do { try await store.reKeyDeviceData(from: from, to: to); return #"{"ok":true}"# }
            catch { return #"{"error":"reKeyFailed"}"# }
        case "device.whoopMergeOffer":
            // One WHOOP entry: whether extra WHOOP entries can be folded in, and which strap stays
            // connected. The rule is `WhoopRowFold.keeper`, the same one the Apple Devices screen asks.
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            struct Wire: Encodable { let needed: Bool; let keeperId: String?; let keeperName: String?; let identityFrom: String? }
            do {
                let offer = try DeviceRegistryStore(dbQueue: store.registryWriter).whoopFoldOffer()
                return CoreRead.json(Wire(needed: offer.needed, keeperId: offer.keeperId,
                                          keeperName: offer.keeperName, identityFrom: offer.identityFrom))
            } catch { return #"{"error":"offerFailed"}"# }
        case "device.whoopMergeBind":
            // Step 1 of the merge: the canonical row adopts the keeper's strap BEFORE any row moves, so
            // the live link can be re-targeted and nothing is written under an id being emptied.
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            let identity = args["identityFrom"] as? String
            let writer = store.registryWriter
            do {
                try await Task.detached { try WhoopRowFold.bind(writer: writer, identityFrom: identity) }.value
                return #"{"ok":true}"#
            } catch { return #"{"error":"bindFailed"}"# }
        case "device.whoopMergeStep":
            // One chunk of the merge. A chunk at a time rather than one call with a progress closure,
            // which cannot cross this bridge; `done` says when to stop asking. Interrupting between
            // steps is safe, the next step continues.
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            let identity = args["identityFrom"] as? String
            let chunk = max(1, int("chunk", WhoopRowFold.defaultChunkSize))
            let writer = store.registryWriter
            struct Wire: Encodable { let moved: Int; let done: Bool }
            do {
                let step = try await Task.detached(priority: .utility) {
                    try WhoopRowFold.foldStep(writer: writer, identityFrom: identity, chunkSize: chunk)
                }.value
                return CoreRead.json(Wire(moved: step.moved, done: step.done))
            } catch { return #"{"error":"mergeFailed"}"# }
        case "device.whoopTakeOver":
            // One WHOOP entry at pairing: the strap that replaces the previous one takes over the
            // canonical row instead of becoming a second card.
            let peripheralId = string("peripheralId")
            guard !peripheralId.isEmpty else { return #"{"error":"invalid"}"# }
            guard let (store, _) = ShadowSession.storeAndPath else { return #"{"error":"noStore"}"# }
            struct Wire: Encodable { let took: Bool; let retarget: Bool }
            do {
                let outcome = try WhoopRowFold.takeOver(writer: store.registryWriter, peripheralId: peripheralId,
                                                        model: string("model"), nickname: args["nickname"] as? String,
                                                        makeActive: args["makeActive"] as? Bool ?? false)
                return CoreRead.json(Wire(took: outcome.took, retarget: outcome.needsRetarget))
            } catch { return #"{"error":"takeOverFailed"}"# }
        case "media.configure":
            guard let root = args["root"] as? String, root.hasPrefix("/") else { return #"{"error":"mediaRootMissing"}"# }
            return CoreRead.json(await CoreExerciseMedia.shared.configure(root: URL(fileURLWithPath: root), disabled: args["disabled"] as? Bool ?? false))
        case "media.info": return CoreRead.json(await CoreExerciseMedia.shared.info())
        case "media.install":
            return CoreRead.json(await CoreExerciseMedia.shared.install(archive: URL(fileURLWithPath: string("archive"))))
        case "media.cancel": await CoreExerciseMedia.shared.cancel(); return ok(true)
        case "media.disabled": await CoreExerciseMedia.shared.setDisabled(args["disabled"] as? Bool ?? false); return ok(true)
        case "media.delete": return ok(await CoreExerciseMedia.shared.delete())
        case "tile.units":
            // The unit each measure is written in, from the one catalogue. Asked once and held, like the
            // colours. Without it Android's catalogue tiles stood with no unit at all: "91" beside the
            // iPhone's "91 g", on one account (2026-11-19).
            // `uniquingKeysWith`, not `uniqueKeysWithValues`: the same measure offered under two gallery
            // sections is a display question, and a trap inside the core would answer it by taking the
            // app down on the first tile that asks for its unit.
            return CoreRead.json(Dictionary(TileMeasures.keys.compactMap { key in
                MetricCatalog.all.first { $0.key == key }.map { (key, $0.unit) }
            }, uniquingKeysWith: { first, _ in first }))
        case "tile.tints":
            // Which colour each measure is drawn in, by name. The palette is each phone's own; which
            // measure gets which name is one decision, and it is `TileMeasures.tint`. Asked once and
            // held, because it never changes while the app runs.
            return CoreRead.json(Dictionary(TileMeasures.keys.map { ($0, TileMeasures.tint(forKey: $0).rawValue) },
                                            uniquingKeysWith: { first, _ in first }))
        case "demo.person":
            // The demo account's body, from the shared dataset, so the emulator's profile and the
            // iPhone's hold one person. Kotlin writes it into its own prefs file; the figures are not
            // its to choose.
            return CoreRead.json(DemoDataset.person())
        case "prefs.read": return CorePrefs.readJSON()
        case "prefs.write": return ok(CorePrefs.write(key: string("key"), value: args["value"]))
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
        // The pull gesture's rules: pure policy, answered before the store is needed, because a wearer
        // can pull on a phone whose store has not opened yet.
        if let answer = CoreSourceRefresh.run(op, args) { return answer }
        guard let (store, _) = ShadowSession.storeAndPath, let reader = ShadowSession.reader else {
            return #"{"error":"noStore"}"#
        }
        // Correcting, retiring and restoring a night, on the rows the night itself names (`CoreSleepEdit`).
        if let answer = await CoreSleepEdit.run(op, args, store: store, reader: reader) { return answer }
        if op == "demo.seed" {
            // The whole demo account, written once and only into a store that has no days of its own, so it
            // can never overwrite a real one. The caller gates it to a debug build.
            let wrote = (try? await DemoDataset.seedIfEmpty(store: store)) ?? false
            return CoreRead.json(["seeded": wrote])
        }
        if op.hasPrefix("input.") || op.hasPrefix("lanes.") { return await CoreUserInputs.run(op, json: argsJSON, store: store) }
        // The coach and the goal screens built on its stores run over the persisted goals (`CoreGoalHost`).
        if op.hasPrefix("coach.") || op.hasPrefix("goals.onboarding") || op.hasPrefix("goals.editor") {
            return await CoreGoalHost.with(store) {
                if op.hasPrefix("coach.drafts.goal") { return CoreRead.json(await CoreGoalReview.run(op, args)) }
                if op.hasPrefix("coach.drafts") { return CoreRead.json(await CoreCoachDrafts.run(op, args, store: reader.store)) }
                if op.hasPrefix("goals.onboarding") {
                    return CoreRead.json(await CoreGoalOnboarding.run(op, args, weightKg: (args["weightKg"] as? NSNumber)?.doubleValue ?? 0))
                }
                if op.hasPrefix("goals.editor") {
                    return CoreRead.json(await CoreGoalEditor.run(op, args, weightKg: (args["weightKg"] as? NSNumber)?.doubleValue ?? 0))
                }
                return await CoreCoach.run(op, args: args, reader: reader)
            }
        }
        if op.hasPrefix("ecg.") { return await CoreEcg.run(op, args: args, store: store) }
        if op.hasPrefix("food.plan") { return await CoreDietPlan.run(op, args: args, store: store, reader: reader) }
        if op.hasPrefix("food.") { return await CoreFood.run(op, args: args, store: store) }
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
            let settings = CoreGoalEnergy.settings(args)
            do {
                return op == "goals.snapshot"
                    ? CoreRead.json(try await CoreGoals.snapshot(reader: reader, settings: settings))
                    : CoreRead.json(try await CoreGoals.setup(reader: reader, settings: settings))
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "goals.lines":
            do {
                return CoreRead.json(try await CoreGoals.lines(reader: reader, settings: CoreGoalEnergy.settings(args),
                    workoutId: args["workoutId"] as? String, day: args["day"] as? String,
                    draft: args["draft"] as? Bool ?? false))
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "goals.addPeriod":
            return CoreRead.json(await CoreGoals.addPeriodGoal(store: store, metric: string("metric"),
                period: string("period"), target: (args["target"] as? NSNumber)?.doubleValue ?? 0,
                threshold: (args["threshold"] as? NSNumber)?.doubleValue, habitKey: args["habitKey"] as? String,
                habitWantsYes: args["habitWantsYes"] as? Bool ?? true))
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
            let settings = CoreGoalEnergy.settings(args)
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
                                                                reason: args["reason"] as? String,
                                                                value: (args["value"] as? NSNumber)?.doubleValue))
        case "diagnostics.skinTempBackfill":
            // #1853: the Test Centre's on-demand fill of NULL skin-temperature absolutes, as Apple runs it.
            let result = await SkinTempBackfillWalker(store: store).runBackfill()
            return CoreRead.json(["line": result.summary, "filled": "\(result.filledCount)"])
        case "stress.day":
            return CoreRead.json(await CoreStress.day(reader: reader, personalBaseline: args["personal"] as? Bool ?? false))
        case "stress.fingerprint":
            return CoreRead.json(["fingerprint": await CoreStress.fingerprint(reader: reader)])
        case "goals.motivation":
            return CoreRead.json(await CoreGoals.changeMotivation(store: store, seen: args["seen"] as? [String] ?? [],
                                                                  enabled: args["enabled"] as? Bool))
        case "goals.notices":
            let host = CoreGoalNotices.Host(kinds: args["kinds"] as? [String] ?? [], quiet: args["quiet"] as? Bool ?? false,
                eveningMinute: int("eveningMinute", 19 * 60), workoutInProgress: args["workoutInProgress"] as? Bool ?? false,
                appIsActive: args["appIsActive"] as? Bool ?? false, state: args["noticeState"] as? String)
            do {
                return CoreRead.json(try await CoreGoalNotices.evaluate(reader: reader, settings: CoreGoalEnergy.settings(args),
                                                                        host: host))
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "goals.journey":
            do {
                return CoreRead.json(try await CoreLongTermGoals.journey(reader: reader, settings: CoreGoalEnergy.settings(args),
                                                                         id: string("id")))
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "goals.longTermPage":
            do {
                return CoreRead.json(try await CoreLongTermGoals.page(reader: reader, settings: CoreGoalEnergy.settings(args),
                                                                      id: string("id")))
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "body.snapshot":
            return CoreRead.json(await CoreBody.snapshot(reader: reader, days: int("days", 120),
                comparisonDays: int("comparisonDays", 42), equation: NavyEquation(rawValue: string("equation"))))
        case "body.rows":
            let values = ((args["values"] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            let epoch = (args["takenAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            return CoreRead.json(CoreBody.rows(values: values, deviceId: string("deviceId"),
                                               takenAt: Date(timeIntervalSince1970: epoch), note: args["note"] as? String))
        case "body.logWeight":
            guard let kg = (args["kg"] as? NSNumber)?.doubleValue else { return #"{"error":"invalid"}"# }
            let epoch = (args["takenAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
            return ok(await CoreBody.logWeight(store: store, kg: kg, at: Date(timeIntervalSince1970: epoch), note: args["note"] as? String))
        case "body.deleteWeight":
            return ok(await CoreBody.deleteWeight(store: store, id: string("id")))
        case "energy.plan":
            let settings = CoreGoalEnergy.settings(args)
            return CoreRead.json(await CoreEnergyPlan.plan(reader: reader, settings: settings,
                activity: ActivityLevel(rawValue: string("activity")) ?? .light,
                targetKgPerWeek: (args["targetKgPerWeek"] as? NSNumber)?.doubleValue ?? 0))
        case "charge.usualRange":
            // A Charge driver's usual range (`DriverUsualRange`): the middle half of the nights before, the night placed
            // on a 0 to 100 track. `null` under seven nights, where the row keeps its single usual value.
            let before = ((args["before"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            guard let value = (args["value"] as? NSNumber)?.doubleValue,
                  let q = DriverUsualRange.middleHalf(before) else { return "null" }
            let placed = DriverUsualRange.place(value, low: q.low, high: q.high)
            return CoreRead.json(["low": q.low, "high": q.high, "position": placed.position,
                                  "bandLow": placed.band.lowerBound, "bandHigh": placed.band.upperBound])
        case "metric.detailInsights":
            // A measure's detail page (`MetricDetailInsights`): statistics, change and correlations over the window
            // the page shows. Series arrive as [[day, value], ...].
            func points(_ name: String) -> [(day: String, value: Double)] {
                ((args[name] as? [[Any]]) ?? []).compactMap { pair in
                    guard pair.count == 2, let day = pair[0] as? String, let value = (pair[1] as? NSNumber)?.doubleValue
                    else { return nil }
                    return (day, value)
                }
            }
            return CoreRead.json(await CoreMetricDetail.insights(reader: reader, catalogKey: string("key"),
                catalogSource: string("source"), series: points("series"), windowed: points("windowed"),
                isAll: (args["isAll"] as? Bool) ?? false, revision: int("revision", 0)))
        case "read.liveEffort":
            // Today's Effort as a Today screen must show it: the live score floored at the stored row.
            return CoreRead.json(["value": await CoreRead.liveEffort(
                reader: reader, hrMaxOverride: (args["hrMaxOverride"] as? NSNumber)?.intValue ?? 0,
                age: (args["age"] as? NSNumber)?.intValue ?? 0,
                restingHr: (args["restingHr"] as? NSNumber)?.intValue,
                storedEffort: (args["storedEffort"] as? NSNumber)?.doubleValue,
                mode: DayCycleMode.persisted(args["dayCycleMode"] as? String))])
        case "read.hasAnyDay":
            // The first-run question, as one boolean: "is there any day at all" (`CoreRead.hasAnyDay`).
            return CoreRead.json(["any": await CoreRead.hasAnyDay(reader: reader)])
        case "read.dailyRows":
            return CoreRead.json(await CoreRead.dailyRows(from: string("from"), to: string("to"), reader: reader))
        case "read.resolvedSeries":
            // `Repository.resolvedSeries`: one metric across every compatible source, first candidate wins per day.
            let r = await MetricResolver.resolve(store: reader.store, key: string("key"), preferredSource: string("source"),
                                                 actualWhoopSource: string("whoopSource"), from: string("from"), to: string("to"),
                                                 suppressedSleepWakeDays: Set(args["suppressedWakeDays"] as? [String] ?? []))
            return CoreRead.json(CoreRead.ResolvedSeries(r))
        case "read.tileHistory":
            // One Today tile's history, by the route that measure needs (`StoreReader.tileHistory`): the one
            // step resolver for steps, one skin-temperature scale, the gallery's source for the rest. Android
            // asks for the KEY only and never names a source, so the two phones cannot read a tile's history
            // from different places — which is how its weight tile came to have no series at all.
            let key = string("key")
            // The window comes from the shared table unless the caller names one, so neither phone decides
            // how much history a tile holds (`TileMeasures.windowDays`).
            let today = LogicalDay.key(Date())
            let from = args["from"] as? String
                ?? MeasureFacts.dayKey(today, minusDays: TileMeasures.windowDays(forKey: key) - 1)
            let to = args["to"] as? String ?? today
            let prefer = SkinTempDisplay.Kind(rawValue: string("skinTempPrefer")) ?? .absolute
            // The merged daily rows are Explore's lowest layer as well as skin temperature's only source, so
            // every key needs them.
            let rows = await CoreRead.dailyRows(from: from, to: to, reader: reader)
            let history = await reader.tileHistory(key: key, from: from, to: to, dailyRows: rows,
                                                   suppressedSleepWakeDays: Set(args["suppressedWakeDays"] as? [String] ?? []),
                                                   skinTempPrefer: prefer)
            struct Wire: Encodable { let days: [String]; let values: [Double]; let skinKind: String? }
            return CoreRead.json(Wire(days: history.days, values: history.values,
                                      skinKind: history.skinKind?.rawValue))
        case "read.metricSeries":
            // One source's stored series verbatim, as `WhoopStore.metricSeries` holds it. These stored reads answer
            // `null` when the store throws, so Android reads Room instead of showing an empty list (`stored`).
            return await stored { try await reader.store.metricSeries(deviceId: string("deviceId"), key: string("key"),
                                                                      from: string("from"), to: string("to")) }
        case "read.metricKeys":
            return await stored { try await reader.store.metricKeys(deviceId: string("deviceId")) }
        case "read.metricCount":
            return await stored {
                let count = try await reader.store.metricSeriesKeyCount(deviceId: string("deviceId"), key: string("key"))
                return ["count": count]
            }
        case "read.appleDaily":
            return await stored { try await reader.store.appleDaily(deviceId: string("deviceId"), from: string("from"), to: string("to")) }
        case "read.dailyMetrics":
            return await stored { try await reader.store.dailyMetrics(deviceId: string("deviceId"), from: string("from"), to: string("to")) }
        case "read.labMarkers":
            // The Lab Book's readings for one category, as Apple's `LabBookView` reads them.
            return await stored { try await reader.store.labMarkers(deviceId: string("deviceId"), category: string("category")) }
        case "read.sleepSessions":
            // `StoreReader.unionSleepSessions` and its computed twin: every block of the union with near-identical
            // nights collapsed, naps kept, as `Repository` reads them for the Sleep screens.
            let from = int("from", 0), to = int("to", Int(Date().timeIntervalSince1970)), limit = int("limit", 4000)
            let sessions = int("computed", 0) == 1
                ? await reader.unionComputedSleepSessions(from: from, to: to, limit: limit)
                : await reader.unionSleepSessions(from: from, to: to, limit: limit)
            return CoreRead.json(["sessions": sessions])
        case "read.habitualMidsleep":
            // `Repository.habitualMidsleepSec`: the learned habitual midsleep, nil during the cold start (#547).
            let value = await reader.habitualMidsleepSec(from: int("from", 0), to: int("to", Int(Date().timeIntervalSince1970)),
                                                         offsetSec: int("offsetSec", TimeZone.current.secondsFromGMT()))
            return CoreRead.json(CoreRead.OptionalValue(value: value))
        case "export.route":
            return await CoreRouteExport.run(args, reader: reader)
        case "read.workouts":
            return CoreRead.json(await CoreRead.workouts(days: (args["days"] as? Int) ?? 4000,
                                                         dismissed: args["dismissedWorkouts"] as? [String] ?? [], reader: reader))
        case "sleep.debt":
            return CoreRead.json(await CoreSleepDebt.read(reader: reader))
        case "sleep.nightFacts":
            // What the Sleep page states about one night in figures rather than shares: time in bed,
            // efficiency, hours asleep and restorative sleep, each against the wearer's usual
            // (`NightSummaryFacts`). The night's own minutes come from the screen, so the card states the
            // night it is showing; the usual comes from here, so neither phone keeps its own version of it.
            func minutes(_ key: String) -> Double { (args[key] as? NSNumber)?.doubleValue ?? 0 }
            // The stored nights come from the screen, which already holds its day rows, as the Apple
            // screens pass theirs: the averages are worked out HERE, once, and only their input travels.
            // Reading them again from the store would have cost a 120-day merge for every night the
            // wearer pages to, for two averages over thirty sleep totals.
            func number(_ row: [String: Any], _ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue }
            let nights = (args["nights"] as? [[String: Any]] ?? []).map {
                NightSummaryFacts.NightRow(asleepMin: number($0, "asleepMin"), deepMin: number($0, "deepMin"),
                                           remMin: number($0, "remMin"))
            }
            let facts = NightSummaryFacts.read(
                night: NightSummaryFacts.Night(inBedMin: minutes("inBedMin"), asleepMin: minutes("asleepMin"),
                                               deepMin: minutes("deepMin"), remMin: minutes("remMin"),
                                               storedEfficiency: (args["storedEfficiency"] as? NSNumber)?.doubleValue),
                nights: nights)
            struct Wire: Encodable {
                let inBedMin: Double, asleepMin: Double, restorativeMin: Double
                let efficiencyPct: Double?, typicalAsleepMin: Double?, typicalRestorativeMin: Double?
            }
            return CoreRead.json(Wire(inBedMin: facts.inBedMin, asleepMin: facts.asleepMin,
                                      restorativeMin: facts.restorativeMin, efficiencyPct: facts.efficiencyPct,
                                      typicalAsleepMin: facts.typicalAsleepMin,
                                      typicalRestorativeMin: facts.typicalRestorativeMin))
        case "energy.today":
            guard let s = await CoreEnergyDetail.today(reader: reader, settings: CoreGoalEnergy.settings(args)) else { return "null" }
            return CoreRead.json(s)
        case "energy.detail":
            return CoreRead.json(await CoreEnergyDetail.read(reader: reader, settings: CoreGoalEnergy.settings(args),
                                                             day: string("day"), comparison: string("comparison")))
        case "energy.switchFormula":
            // Append-only, as `EnergyPlanStore.switchFormula` does on Apple: the switch applies from today.
            guard let formula = BasalFormula(rawValue: string("formula")) else { return #"{"error":"invalid"}"# }
            let next = BmrFormulaLog.decode(string("log")).appending(formula, effectiveFrom: StoreReader.localDayKey(Date()))
            return CoreRead.json(["log": next.encodedJSON()])
        case "energy.recordIntake":
            guard let kcal = (args["kcal"] as? NSNumber)?.doubleValue else { return #"{"error":"invalid"}"# }
            return ok(await CoreEnergyPlan.recordIntake(store: store, kcal: kcal))
        case "healthConnect.workoutHeartRate":
            // Health Connect sessions' heart rate, filed by the minute beside each session, then their Effort from
            // the shared fill (`WorkoutHeartRateFills.fillHealthConnect`), as iOS fills Apple Health's workouts.
            let maxHR = (args["maxHR"] as? NSNumber)?.doubleValue ?? Double(StrainScorer.defaultMaxHR())
            var starts: [Int] = []
            for w in args["workouts"] as? [[String: Any]] ?? [] {
                guard let start = (w["startTs"] as? NSNumber)?.intValue, let sport = w["sport"] as? String else { continue }
                starts.append(start)
                let samples = (w["samples"] as? [[NSNumber]] ?? []).compactMap { p in
                    p.count == 2 ? (ts: p[0].intValue, bpm: p[1].doubleValue) : nil
                }
                try? await WorkoutHeartRateFills.fileHealthConnectMinutes(store: store, startTs: start, sport: sport, samples: samples)
            }
            guard let lo = starts.min(), let hi = starts.max() else { return #"{"filled":0}"# }
            let outcome = (try? await WorkoutHeartRateFills.fillHealthConnect(reader: reader, from: lo, to: hi, maxHR: maxHR)) ?? .untouched
            return #"{"filled":\#(outcome.filled)}"#
        case "cycle.read":
            // The cycle page from the reading the iPhone runs (`CycleReading.swift`): phase, snapshot, pattern, log.
            return CoreRead.json(await CoreCycle.read(reader: reader, showFertile: (args["showFertile"] as? Bool) ?? true,
                learning: (args["learning"] as? Bool) ?? false,
                dismissedWorkouts: args["dismissedWorkouts"] as? [String] ?? []))
        case "cycle.phase":
            guard let phase = await CoreCycle.phase(reader: reader) else { return "null" }
            return CoreRead.json(phase)
        case "cycle.saveLog":
            // Today's notes, and a new period start when flow begins with none in the last ten days.
            let decoder = JSONDecoder()
            func day(_ k: String) -> CoreCycle.LogDay? {
                (args[k] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { try? decoder.decode(CoreCycle.LogDay.self, from: $0) }
            }
            guard let log = day("log"), let previous = day("previous") else { return #"{"error":"invalid"}"# }
            let started = await CoreCycle.save(store: store, day: string("day"), log: log, previous: previous,
                                               starts: args["starts"] as? [String] ?? [])
            return CoreRead.json(["ok": true, "startLogged": started])
        case "rhythm.snapshot":
            return CoreRead.json(await CoreRhythmAge.snapshot(reader: reader))
        case "steps.setSource":
            // Where daily steps come from (`StepsSource`): the choice, and the AgeLess weeks, the only stored values
            // that read steps, rebuilt by the next pass as on the iPhone.
            guard let source = StepsSource(rawValue: string("source")) else { return #"{"error":"invalid"}"# }
            UserDefaults.standard.set(source.rawValue, forKey: StepsSource.defaultsKey)
            try? await DailyAnalysis.deleteHealthspanWeeks(store: store, deviceId: reader.activeDeviceId)
            return ok(true)
        case "ageless.snapshot":
            return CoreRead.json(await CoreAgeLess.snapshot(reader: reader, age: int("age", 0), sex: string("sex")))
        case "momentum.feed":
            let settings = CoreGoalEnergy.settings(args)
            do {
                return CoreRead.json(try await CoreMomentum.feed(reader: reader, settings: settings,
                    hrvEpoch: (args["hrvEpoch"] as? NSNumber)?.doubleValue ?? 0,
                    recoveryEpoch: (args["recoveryEpoch"] as? NSNumber)?.doubleValue ?? 0,
                    snoozedRaw: string("snoozed"), lastKind: string("lastKind"),
                    lastAt: (args["lastAt"] as? NSNumber)?.doubleValue ?? 0,
                    healthAlertCopy: (args["healthAlert"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    strapHoursRemaining: (args["strapHoursRemaining"] as? NSNumber)?.doubleValue,
                    cyclePhase: args["cyclePhase"] as? String,
                    cycleDayLow: (args["cycleDayLow"] as? NSNumber)?.intValue,
                    cycleDayHigh: (args["cycleDayHigh"] as? NSNumber)?.intValue))
            } catch {
                return #"{"error":"goalState"}"#
            }
        case "timeline.admit":
            // The new design's Today notices through the one admission rule Apple uses (`TimelineFeed.admit`): a
            // topic speaks at most once a week unless it got clearly worse. The log stays opaque to the host.
            let candidates = (args["candidates"] as? [[String: Any]] ?? []).compactMap { c -> TimelineFeed.Candidate? in
                guard let key = c["key"] as? String, let topic = TimelineFeed.Topic(rawValue: c["topic"] as? String ?? "") else { return nil }
                return TimelineFeed.Candidate(key: key, topic: topic, severity: (c["severity"] as? NSNumber)?.doubleValue ?? 2,
                                              isEvent: (c["isEvent"] as? Bool) ?? false)
            }
            let log = string("log").data(using: .utf8).flatMap { try? JSONDecoder().decode([TimelineFeed.Shown].self, from: $0) } ?? []
            let lessOften = Set(args["lessOften"] as? [String] ?? [])
            let now = Date(timeIntervalSince1970: (args["now"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970)
            let result = TimelineFeed.admit(candidates, log: log, day: string("day"), now: now) { topic in
                lessOften.contains(topic.rawValue) ? 2 * TimelineFeed.cooldownDays : TimelineFeed.cooldownDays
            }
            let encoded = (try? JSONEncoder().encode(result.log)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            struct Admitted: Encodable { let key: String; let at: Double }
            struct Out: Encodable { let admitted: [Admitted]; let log: String }
            return CoreRead.json(Out(admitted: result.admitted.map { Admitted(key: $0.candidate.key, at: $0.at.timeIntervalSince1970) },
                                     log: encoded))
        case "momentum.snooze":
            return CoreRead.json(["snoozed": await CoreMomentum.snooze(kind: string("kind"), snoozedRaw: string("snoozed"))])
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
        // Plans (Apple: the Training page's plan list, the plan page, the builder and the ready-made
        // plans). The deciding and the counting stay in the core; Kotlin asks and draws.
        case "plans.snapshot":
            return CoreRead.json(await CorePlans.snapshot(store: store, today: string("day")))
        case "plans.review":
            let asked = (args["minutes"] as? NSNumber)?.intValue
            guard let review = await CorePlans.review(store: store, planId: string("id"),
                                                      askedMinutes: asked)
            else { return #"{"error":"noPlan"}"# }
            return CoreRead.json(review)
        case "plans.save":
            guard let id = await CorePlans.save(store: store, args: args) else { return ok(false) }
            return CoreRead.json(["id": id])
        case "plans.activate":
            return ok(await CorePlans.activate(store: store, id: string("id"), day: string("day")))
        case "plans.deactivate":
            return ok(await CorePlans.deactivate(store: store, id: string("id"), day: string("day")))
        case "plans.delete":
            return ok(await CorePlans.delete(store: store, id: string("id")))
        case "plans.duplicate":
            guard let id = await CorePlans.duplicate(store: store, id: string("id"),
                                                     title: string("title")) else { return ok(false) }
            return CoreRead.json(["id": id])
        case "plans.build":
            guard let preview = await CorePlans.build(store: store, args: args, today: string("day"))
            else { return #"{"error":"noPlan"}"# }
            return CoreRead.json(preview)
        case "plans.useTemplate":
            guard let id = await CorePlans.useTemplate(
                store: store, id: string("id"),
                weightStepKg: (args["weightStepKg"] as? NSNumber)?.doubleValue ?? 2.5)
            else { return ok(false) }
            return CoreRead.json(["id": id])
        case "plans.blockRuns":
            return CoreRead.json(await CorePlans.blockRuns(store: store, planId: string("id"),
                                                           today: string("day")))
        case "plans.routine":
            guard let detail = await CorePlans.routine(store: store, id: string("id"))
            else { return #"{"error":"noRoutine"}"# }
            return CoreRead.json(detail)
        case "plans.createRoutine":
            guard let id = await CorePlans.createRoutine(store: store, title: string("title"),
                                                        planId: args["planId"] as? String)
            else { return ok(false) }
            return CoreRead.json(["id": id])
        case "plans.editRoutine":
            return ok(await CorePlans.editRoutine(store: store, args: args))
        case "plans.routineFromWorkout":
            return ok(await CorePlans.routineFromWorkout(store: store, workoutId: string("workoutId"),
                                                         title: string("title"),
                                                         planId: args["planId"] as? String))
        case "activity.list":
            return CoreRead.json(await CoreActivity.list(reader: reader, args: args))
        case "activity.answer":
            return ok(await CoreActivity.answer(reader: reader, args: args))
        case "activity.undo":
            return ok(await CoreActivity.undo(reader: reader, args: args))
        case "today.status":
            let maxHR = (args["maxHR"] as? NSNumber)?.doubleValue ?? Double(StrainScorer.defaultMaxHR())
            return CoreRead.json(await CoreTodayStatus.read(reader: reader, maxHR: maxHR, sex: string("sex"),
                                                            dismissedWorkoutSpans: args["dismissedWorkouts"] as? [String] ?? []))
        case "today.activity":
            return CoreRead.json(CoreTodayStatus.activity())
        case "today.setActivity":
            return ok(CoreTodayStatus.setActivity(state: string("state"), duration: string("duration"),
                                                  customUntil: (args["until"] as? NSNumber)?.intValue))
        case "training.load":
            let maxHR = (args["maxHR"] as? NSNumber)?.doubleValue ?? Double(StrainScorer.defaultMaxHR())
            return CoreRead.json(await CoreTrainingLoad.read(reader: reader, maxHR: maxHR, sex: string("sex"),
                                                             dismissedWorkoutSpans: args["dismissedWorkouts"] as? [String] ?? [],
                                                             exerciseVO2max: args["exerciseVO2max"] as? Bool ?? false))
        case "training.decidePair":
            return ok(await CoreTrainingLoad.decidePair(store: store, ids: args["ids"] as? [String] ?? [],
                                                        merge: args["merge"] as? Bool ?? false))
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
        case "training.previousSets":
            return CoreRead.json(await CoreTraining.previousSets(store: store, reader: reader,
                                                                 dismissedWorkoutSpans: args["dismissedWorkouts"] as? [String] ?? []))
        case "training.draftFigures":
            return CoreRead.json(await CoreTraining.draftFigures(store: store))
        case "training.strapStep":
            return CoreRead.json(await CoreTraining.strapStep(store: store))
        case "training.changeDraft":
            return CoreRead.json(await CoreTraining.changeDraft(store: store, args: args, reader: reader,
                                                                dismissedWorkoutSpans: args["dismissedWorkouts"] as? [String] ?? []))
        case "training.finishDraft":
            let rpe = (args["sessionRPE"] as? NSNumber)?.doubleValue
            let finished = await CoreTraining.finishDraft(store: store, sessionRPE: rpe)
            struct Wire: Encodable { let saved: Bool; let reason: String }
            return CoreRead.json(Wire(saved: finished.workout != nil, reason: finished.outcome.rawValue))
        default:
            return #"{"error":"unknownOp"}"#
        }
    }

    /// A stored read for the host: the value as JSON, or `null` when the store throws, so the caller can tell a
    /// failed read from an empty one.
    private static func stored<T: Encodable>(_ read: () async throws -> T) async -> String {
        guard let value = try? await read() else { return "null" }
        return CoreRead.json(value)
    }
}
