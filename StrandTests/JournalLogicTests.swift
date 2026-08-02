import XCTest
import WhoopStore
@testable import Strand

/// Pins the native-journal merge logic, mirroring the Android JournalLogTest value-for-value so the
/// two platforms merge catalogs and entries identically, question strings are opaque exact-match
/// keys to the effects engines on both sides.
final class JournalLogicTests: XCTestCase {

    private func e(_ day: String, _ q: String, _ yes: Bool) -> JournalEntry {
        JournalEntry(day: day, question: q, answeredYes: yes, notes: nil)
    }

    func testNativeWinsOnCollision() {
        let imported = [e("2026-06-09", "Did you drink any alcohol?", false)]
        let native = [e("2026-06-09", "Did you drink any alcohol?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].answeredYes)
    }

    func testDisjointKeysUnionAndSort() {
        let imported = [e("2026-06-09", "B?", true)]
        let native = [e("2026-06-10", "A?", false), e("2026-06-09", "A?", true)]
        let merged = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(merged.count, 3)
        // Sorted day ASC then question ASC, matches the DAO/store read order.
        XCTAssertEqual(merged.map(\.question), ["A?", "B?", "A?"])
        XCTAssertEqual(merged.map(\.day), ["2026-06-09", "2026-06-09", "2026-06-10"])
    }

    @MainActor
    func testCatalogAdoptsImportedCasing() {
        let cat = JournalCatalogStore.mergeCatalog(imported: ["DID YOU DRINK ANY ALCOHOL?"], custom: [])
        XCTAssertEqual(cat.first, "DID YOU DRINK ANY ALCOHOL?")
        // The starter alcohol question deduped case-insensitively: 9 starters survive + 1 imported.
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count)
    }

    @MainActor
    func testCustomsAppendAndBlanksDrop() {
        let cat = JournalCatalogStore.mergeCatalog(imported: [],
                                                   custom: ["  ", "Did you nap?", "did you NAP?"])
        XCTAssertEqual(Array(cat.prefix(JournalCatalogStore.starterQuestions.count)),
                       JournalCatalogStore.starterQuestions)
        XCTAssertEqual(cat.last, "Did you nap?")
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count + 1)
    }

    @MainActor
    func testImportedMagnesiumWithTrailingWhitespaceDoesNotDoublePrompt() {
        // #224: a WHOOP export leaves a trailing newline / non-breaking space on the cell, so the
        // imported "Did you take magnesium?\n" must fold onto the starter, NOT add a second row.
        let cat = JournalCatalogStore.mergeCatalog(
            imported: ["Did you take magnesium?\n", "Did you take  magnesium?"],
            custom: [])
        let magCount = cat.filter {
            $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                .caseInsensitiveCompare("Did you take magnesium?") == .orderedSame
        }.count
        XCTAssertEqual(magCount, 1)
        // No net growth, both imported variants dedupe against the starter.
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count)
    }

    @MainActor
    func testHiddenQuestionsFilteredOutCaseInsensitively() {
        // Hide one starter (different casing) + one custom; both must drop from the merged catalog.
        let cat = JournalCatalogStore.mergeCatalog(
            imported: [],
            custom: ["Did you nap?"],
            hidden: ["did you drink any alcohol?", "DID YOU NAP?"])
        XCTAssertFalse(cat.contains { $0.caseInsensitiveCompare("Did you drink any alcohol?") == .orderedSame })
        XCTAssertFalse(cat.contains { $0.caseInsensitiveCompare("Did you nap?") == .orderedSame })
        XCTAssertEqual(cat.count, JournalCatalogStore.starterQuestions.count - 1)
    }

    // MARK: - v2 catalog (#322): legacy migration, rename key-stability, grouping, numeric type

    func testLegacyMigrationFoldsTwoArraysIntoItems() {
        // The one-time fold: customs become .bool/.other custom items; hidden starters become hidden
        // marker items; a hidden custom keeps its hidden flag on the single custom item (no dupe).
        let items = JournalCatalogStore.migrateLegacy(
            custom: ["Did you nap?", "Vitamin D"],
            hidden: ["Did you drink any alcohol?", "Vitamin D"])
        // Two customs materialised, both marked custom.
        let customs = items.filter { $0.custom }
        XCTAssertEqual(Set(customs.map(\.canonical)), ["Did you nap?", "Vitamin D"])
        // The hidden custom kept its flag on the SAME item (deduped by norm, not a second row).
        let vitaminD = items.filter { JournalCatalogStore.norm($0.canonical) == JournalCatalogStore.norm("Vitamin D") }
        XCTAssertEqual(vitaminD.count, 1, "a hidden custom must not duplicate")
        XCTAssertTrue(vitaminD[0].hidden)
        // The hidden starter became a hidden non-custom marker in its default group.
        let alcohol = items.first { JournalCatalogStore.norm($0.canonical) == JournalCatalogStore.norm("Did you drink any alcohol?") }
        XCTAssertNotNil(alcohol)
        XCTAssertTrue(alcohol!.hidden)
        XCTAssertFalse(alcohol!.custom)
        XCTAssertEqual(alcohol!.group, .nutrition)
    }

    @MainActor
    func testRenameKeepsCanonicalStableSoHistorySurvives() {
        // THE key-stability guarantee (#322): renaming an item changes only the display label; the
        // stored canonical (the DB/engine join key) is untouched, so all logged + imported history, 
        // which is keyed on the canonical question string, still lines up after a rename.
        let store = JournalCatalogStore()
        store.items = []   // start from a clean catalog for a deterministic assertion
        let canonical = "Did you have caffeine late in the day?"

        // Before: display resolves to the canonical verbatim.
        XCTAssertEqual(store.displayName(for: canonical), canonical)

        store.rename(canonical, to: "Caffeine")

        // After: the DISPLAY changed, the KEY did not.
        XCTAssertEqual(store.displayName(for: canonical), "Caffeine")
        let item = store.item(for: canonical)
        XCTAssertNotNil(item)
        XCTAssertEqual(item!.canonical, canonical,
                       "rename must NEVER change the canonical, history is keyed on it")
        XCTAssertEqual(item!.displayName, "Caffeine")

        // A journal write / effect lookup for this behaviour still keys on the canonical, so a row
        // logged BEFORE the rename (under the canonical) is found AFTER the rename by the same key.
        let resolved = store.resolvedItems(imported: [], includeHidden: false)
        let caffeine = resolved.first { $0.canonical == canonical }
        XCTAssertEqual(caffeine?.display, "Caffeine")
        XCTAssertEqual(caffeine?.canonical, canonical,
                       "the engine key is preserved end to end, logged/imported days still join")

        // Clearing the rename (blank) falls back to the canonical.
        store.rename(canonical, to: "   ")
        XCTAssertEqual(store.displayName(for: canonical), canonical)
        XCTAssertEqual(store.item(for: canonical)?.canonical, canonical)
    }

    @MainActor
    func testSetGroupAndKindPreserveCanonical() {
        let store = JournalCatalogStore()
        store.items = []
        let canonical = "Did you take magnesium?"
        store.setGroup(canonical, to: .supplements)
        store.setKind(canonical, to: .numeric(unitLabel: "mg"))
        let item = store.item(for: canonical)
        XCTAssertEqual(item?.canonical, canonical, "regroup/retype never touch the key")
        XCTAssertEqual(item?.group, .supplements)
        XCTAssertTrue(item?.kind.isNumeric ?? false)
        XCTAssertEqual(item?.kind.unitLabel, "mg")
    }

    @MainActor
    func testResolvedItemsGroupStartersByDefaultAndDropHidden() {
        let store = JournalCatalogStore()
        store.items = []
        let resolved = store.resolvedItems(imported: [], includeHidden: false)
        // Every starter is present with a default group and .bool kind.
        XCTAssertEqual(resolved.count, JournalCatalogStore.starterQuestions.count)
        let alcohol = resolved.first { $0.canonical == "Did you drink any alcohol?" }
        XCTAssertEqual(alcohol?.group, .nutrition)
        XCTAssertFalse(alcohol?.kind.isNumeric ?? true)
        // Hidden items are dropped unless includeHidden.
        store.remove("Did you drink any alcohol?")
        let afterHide = store.resolvedItems(imported: [], includeHidden: false)
        XCTAssertFalse(afterHide.contains { $0.canonical == "Did you drink any alcohol?" })
        let withHidden = store.resolvedItems(imported: [], includeHidden: true)
        XCTAssertTrue(withHidden.contains { $0.canonical == "Did you drink any alcohol?" && $0.hidden })
    }

    @MainActor
    func testAddCustomNumericItem() {
        let store = JournalCatalogStore()
        store.items = []
        store.addCustom("Water (L)", kind: .numeric(unitLabel: "L"), group: .nutrition)
        XCTAssertTrue(store.isCustom("Water (L)"))
        let item = store.item(for: "Water (L)")
        XCTAssertEqual(item?.group, .nutrition)
        XCTAssertEqual(item?.kind.unitLabel, "L")
    }

    func testNumericJournalKeyIsNamespaced() {
        // The InsightsView folds a numeric journal series under a namespaced key that can never
        // collide with a fixed metric outcome ("recovery" / "hrv" / …).
        let key = InsightsView.numericJournalKey("Caffeine (mg)")
        XCTAssertTrue(key.hasPrefix("journal.numeric:"))
        XCTAssertNotEqual(key, "recovery")
        XCTAssertNotEqual(key, "hrv")
    }

    // MARK: - Merging duplicate WHOOP wordings
    //
    // A WHOOP export carries several wordings for the same habit, and the question string is the key
    // everywhere — the journal's primary key, `byBehaviour`, the coach's analyser — so two wordings
    // read as two habits with half the history each. Merging folds them at READ time: these pin that
    // nothing is invented, nothing is lost, and the winner on a contested day is predictable.

    private func alias(_ target: String, _ folded: [String]) -> [JournalCatalogItem] {
        [JournalCatalogItem(canonical: target, displayName: nil, kind: .bool, group: .other,
                            sortIndex: 0, hidden: false, custom: false, aliases: folded)]
    }

    func testAliasMapIsKeyedLikeEveryOtherIdentityCheck() {
        let items = alias("Did you drink any alcohol?", ["  HAVE you had ALCOHOL? \n"])
        let map = JournalCatalogStore.aliasMap(items)
        XCTAssertEqual(map[JournalCatalogStore.norm("Have you had alcohol?")], "Did you drink any alcohol?")
        XCTAssertTrue(JournalCatalogStore.aliasMap([]).isEmpty)
    }

    func testAnUntouchedCatalogFoldsExactlyLikeMergeJournal() {
        // The zero-merge path must be the old behaviour, not merely similar to it.
        let imported = [e("2026-06-09", "Did you drink any alcohol?", false)]
        let native = [e("2026-06-09", "Did you drink any alcohol?", true)]
        XCTAssertEqual(JournalMerge.fold(imported: imported, native: native, aliases: [:]),
                       Repository.mergeJournal(imported: imported, native: native))
    }

    func testFoldedDayKeepsOneRealRowAndNeverOrsTheAnswers() {
        // Both wordings answered the same day, and they disagree. The result is ONE of them verbatim —
        // never "yes because somewhere it said yes".
        let target = "Did you drink any alcohol?"
        let items = alias(target, ["Alcohol?"])
        let folded = JournalMerge.fold(
            imported: [e("2026-06-09", target, false),
                       e("2026-06-09", "Alcohol?", true)],
            native: [], aliases: JournalCatalogStore.aliasMap(items),
            aliasOrder: JournalCatalogStore.aliasOrder(items))
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].question, target)
        XCTAssertFalse(folded[0].answeredYes, "the target's own row outranks a folded wording")
    }

    func testFoldDayTargetOutranksTheFirstAliasToo() {
        // Alias positions are zero-based. The read rank reserves zero for the target and offsets every
        // alias by one; otherwise the first alias ties the target and alphabetical order picks a winner.
        let target = "Did you drink any alcohol?"
        let items = alias(target, ["Alcohol?"])
        let folded = JournalMerge.foldDay([target: false, "Alcohol?": true],
                                          aliases: JournalCatalogStore.aliasMap(items),
                                          aliasOrder: JournalCatalogStore.aliasOrder(items))
        XCTAssertEqual(folded[target], false)
    }

    func testNativeBeatsImportedAcrossAMerge() {
        // The user's own answer is their most recent statement, whichever wording carries it — the
        // same precedence mergeJournal already applies within one question.
        let map = [JournalCatalogStore.norm("Alcohol?"): "Did you drink any alcohol?"]
        let folded = JournalMerge.fold(
            imported: [e("2026-06-09", "Did you drink any alcohol?", false)],
            native: [e("2026-06-09", "Alcohol?", true)],
            aliases: map)
        XCTAssertEqual(folded.count, 1)
        XCTAssertTrue(folded[0].answeredYes)
        XCTAssertEqual(folded[0].question, "Did you drink any alcohol?", "renamed onto the target")
    }

    func testEarlierMergeWinsBetweenTwoFoldedWordings() {
        let target = "Did you drink any alcohol?"
        let map = [JournalCatalogStore.norm("Alcohol?"): target,
                   JournalCatalogStore.norm("Any booze?"): target]
        let order = JournalCatalogStore.aliasOrder(alias(target, ["Alcohol?", "Any booze?"]))
        let folded = JournalMerge.fold(imported: [e("2026-06-09", "Any booze?", false),
                                                  e("2026-06-09", "Alcohol?", true)],
                                       native: [], aliases: map, aliasOrder: order)
        XCTAssertEqual(folded.count, 1)
        XCTAssertTrue(folded[0].answeredYes, "the first-merged wording wins the tie")
    }

    func testFoldingLosesNoDayAndTouchesNoUnmergedRow() {
        let map = [JournalCatalogStore.norm("Alcohol?"): "Did you drink any alcohol?"]
        let input = [e("2026-06-09", "Alcohol?", true),
                     e("2026-06-10", "Did you drink any alcohol?", false),
                     e("2026-06-11", "Did you take magnesium?", true)]
        let folded = JournalMerge.fold(imported: input, native: [], aliases: map)
        XCTAssertEqual(Set(folded.map(\.day)), Set(input.map(\.day)), "no day disappears")
        XCTAssertEqual(folded.first { $0.day == "2026-06-11" }?.question, "Did you take magnesium?",
                       "an unmerged question is passed through untouched")
    }

    @MainActor
    func testMergedWordingLeavesTheListAndComesBackOnSeparate() {
        let store = JournalCatalogStore()
        store.items = []
        let target = "Did you drink any alcohol?"
        store.merge("Alcohol?", into: target)
        let merged = store.resolvedItems(imported: ["Alcohol?", target])
        XCTAssertFalse(merged.contains { $0.canonical == "Alcohol?" })
        XCTAssertTrue(merged.contains { $0.canonical == target })

        store.unmerge("Alcohol?")
        let separated = store.resolvedItems(imported: ["Alcohol?", target])
        XCTAssertTrue(separated.contains { $0.canonical == "Alcohol?" }, "nothing was destroyed")
    }

    @MainActor
    func testMergingACollectorCarriesItsOwnAliasesAlong() {
        // A → B, then B → C. Without carrying A over it would point at a question that is no longer
        // anywhere, and its history would drop out of the fold entirely.
        let store = JournalCatalogStore()
        store.items = []
        store.merge("Alcohol?", into: "Any booze?")
        store.merge("Any booze?", into: "Did you drink any alcohol?")
        let map = store.aliasMap()
        XCTAssertEqual(map[JournalCatalogStore.norm("Alcohol?")], "Did you drink any alcohol?")
        XCTAssertEqual(map[JournalCatalogStore.norm("Any booze?")], "Did you drink any alcohol?")
    }

    // MARK: - Reading the model's duplicate reply
    //
    // Word-overlap scoring used to live in `JournalMerge` and is gone; the model finds the groups now
    // (`JournalDuplicateReviewer`). What is pinned here is everything AROUND the one request — the
    // prompt, the parse, and above all the validation, since the reply is the only part of this feature
    // the app does not control.

    /// The questions actually sent, and the array every index in the reply is resolved against.
    private let catalogFixture = [
        "Alkohol konsumiert?",                // 1
        "Did you drink any alcohol?",         // 2
        "Did you take magnesium?",            // 3
        "Ein Magnesiumpräparat eingenommen?", // 4
        "Ein Zinkpräparat eingenommen?",      // 5
    ]

    func testTheModelSeesEveryQuestionOnceAndNothingElse() {
        let list = AICoachEngine.journalQuestionList(
            ["  Did you drink any alcohol?  ", "", "Did you drink any alcohol?", "Alkohol konsumiert?"])
        XCTAssertEqual(list, ["Alkohol konsumiert?", "Did you drink any alcohol?"],
                       "the indexed list is trimmed, deduped and stably sorted")
        XCTAssertEqual(list, AICoachEngine.journalQuestionList(list.reversed()),
                       "visible catalog order cannot change what a cached model index names")

        let promptList = AICoachEngine.journalQuestionList(catalogFixture)
        let prompt = AICoachEngine.journalDuplicatePrompt(promptList)
        for (i, q) in promptList.enumerated() {
            XCTAssertTrue(prompt.contains("\(i + 1). \(q)"), "every question is numbered from 1")
        }
    }

    func testAWellFormedReplyBecomesTheGroupItNames() {
        let candidates = AICoachEngine.journalDuplicateCandidates(
            from: "GROUP 1,2\nKEEP 2\nGROUP 3,4\nKEEP 3",
            questions: catalogFixture,
            counts: ["Did you drink any alcohol?": 40, "Alkohol konsumiert?": 4])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].questions,
                       ["Alkohol konsumiert?", "Did you drink any alcohol?"],
                       "the group with the most answers behind it is offered first")
        XCTAssertEqual(candidates[0].suggestedTarget, "Did you drink any alcohol?")
        XCTAssertEqual(candidates[1].suggestedTarget, "Did you take magnesium?",
                       "KEEP names the survivor, even when it is not the longest history")
    }

    func testAnIndexOutsideTheListIsDroppedWithoutTakingTheReplyWithIt() {
        // The containment that matters: the reply is numbers, resolved against our own array, so a
        // model that invents one loses that group and nothing more.
        let candidates = AICoachEngine.journalDuplicateCandidates(
            from: "GROUP 4,999\nKEEP 999\nGROUP 1,2\nKEEP 1",
            questions: catalogFixture, counts: [:])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].questions, ["Alkohol konsumiert?", "Did you drink any alcohol?"])
        XCTAssertEqual(candidates[0].suggestedTarget, "Alkohol konsumiert?")
    }

    func testARepliedGroupThatSurvivesAloneIsNotAGroup() {
        // One valid index left, and a question claimed twice: neither is a duplicate to offer.
        XCTAssertTrue(AICoachEngine.journalDuplicateCandidates(
            from: "GROUP 1,999", questions: catalogFixture, counts: [:]).isEmpty)
        let repeated = AICoachEngine.journalDuplicateCandidates(
            from: "GROUP 1,2\nGROUP 2,3", questions: catalogFixture, counts: [:])
        XCTAssertEqual(repeated.count, 1, "the first group claims question 2; the second is left with one")
    }

    func testSilenceIsSuccessButProseAndBrokenGroupsAreInvalid() {
        XCTAssertEqual(AICoachEngine.journalDuplicateReview(
            from: "", questions: catalogFixture, counts: [:]), .noDuplicates)
        for reply in ["I could not find any duplicates in this list.", "GROUP\nKEEP 1", "KEEP 2"] {
            XCTAssertEqual(AICoachEngine.journalDuplicateReview(
                from: reply, questions: catalogFixture, counts: [:]), .invalid,
                           "an unparseable reply is not presented or cached as no duplicates: \(reply)")
        }
    }

    func testTheParseIsLenientAboutHowTheNumbersAreWritten() {
        let groups = AICoachEngine.parseJournalDuplicateGroups("group: 1, 2\nKeep:  2\nGROUP 3 and 4")
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].indices, [1, 2])
        XCTAssertEqual(groups[0].keep, 2)
        XCTAssertEqual(groups[1].indices, [3, 4])
        XCTAssertNil(groups[1].keep)
    }

    func testADismissedPairKillsTheGroupItAppearsIn() {
        let pair = JournalMerge.pairKey("Alkohol konsumiert?", "Did you drink any alcohol?")
        XCTAssertEqual(pair, JournalMerge.pairKey("Did you drink any alcohol?", "Alkohol konsumiert?"),
                       "the key is order-independent, so dismissing sticks either way round")
        XCTAssertEqual(AICoachEngine.journalDuplicateReview(
            from: "GROUP 1,2", questions: catalogFixture, counts: [:], dismissed: [pair]),
                       .candidates([]),
                       "a valid cached reply stays valid after the user dismisses its only group")
    }

    func testTheSurvivorFallsBackToTheLongestHistoryWhenKeepIsMissing() {
        let candidates = AICoachEngine.journalDuplicateCandidates(
            from: "GROUP 3,4", questions: catalogFixture,
            counts: ["Ein Magnesiumpräparat eingenommen?": 12, "Did you take magnesium?": 88])
        XCTAssertEqual(candidates.first?.suggestedTarget, "Did you take magnesium?",
                       "a sloppy reply costs a default, not the group")
    }

    func testTheCatalogFingerprintIgnoresOrderButNotContent() {
        let a = AICoachEngine.journalCatalogFingerprint(catalogFixture)
        XCTAssertEqual(a, AICoachEngine.journalCatalogFingerprint(catalogFixture.reversed()),
                       "reordering the catalog does not change what the model would be asked, so it "
                       + "must not buy a second request")
        XCTAssertNotEqual(a, AICoachEngine.journalCatalogFingerprint(catalogFixture + ["Sauna?"]))
        XCTAssertNotEqual(AICoachEngine.journalCatalogFingerprint(["ab", "c"]),
                          AICoachEngine.journalCatalogFingerprint(["a", "bc"]),
                          "the separator is what keeps concatenations apart")
    }

    // MARK: - Grouping the catalog
    //
    // The card buckets the resolved catalog ONCE per render and hands each group its slice. It used to
    // call `resolvedItems` — the full merge of imported questions, saved items and starters — inside
    // every one of the six group blocks, on every render. These pin that the cheaper shape is the same
    // shape: same items, same per-group order.

    @MainActor
    func testItemsByGroupKeepsEveryItemExactlyOnce() {
        let store = JournalCatalogStore()
        store.items = []
        let resolved = store.resolvedItems(imported: ["Did you drink any alcohol?", "Any caffeine?"])
        let grouped = JournalLogCard.itemsByGroup(resolved)
        let flattened = grouped.values.flatMap { $0 }
        XCTAssertEqual(flattened.count, resolved.count)
        XCTAssertEqual(Set(flattened.map(\.canonical)), Set(resolved.map(\.canonical)))
    }

    @MainActor
    func testItemsByGroupPutsEachItemUnderItsOwnGroup() {
        let store = JournalCatalogStore()
        store.items = []
        store.addCustom("Sauna", kind: .bool, group: .lifestyle)
        store.addCustom("Water (L)", kind: .numeric(unitLabel: "L"), group: .nutrition)
        let grouped = JournalLogCard.itemsByGroup(store.resolvedItems(imported: []))
        XCTAssertTrue(grouped[.lifestyle]?.contains { $0.canonical == "Sauna" } ?? false)
        XCTAssertTrue(grouped[.nutrition]?.contains { $0.canonical == "Water (L)" } ?? false)
        XCTAssertFalse(grouped[.lifestyle]?.contains { $0.canonical == "Water (L)" } ?? false)
    }

    @MainActor
    func testItemsByGroupOrdersBySortIndexThenDisplay() {
        // The old per-group `filter().sorted()` ordered by (sortIndex, display); the bucketed form has to
        // reproduce it, or a rename would visibly reshuffle a group.
        let store = JournalCatalogStore()
        store.items = [
            JournalCatalogItem(canonical: "b", displayName: nil, kind: .bool, group: .other,
                               sortIndex: 2, hidden: false, custom: true),
            JournalCatalogItem(canonical: "a", displayName: nil, kind: .bool, group: .other,
                               sortIndex: 2, hidden: false, custom: true),
            JournalCatalogItem(canonical: "c", displayName: nil, kind: .bool, group: .other,
                               sortIndex: 1, hidden: false, custom: true),
        ]
        let grouped = JournalLogCard.itemsByGroup(store.resolvedItems(imported: []))
        let others = (grouped[.other] ?? []).filter { ["a", "b", "c"].contains($0.canonical) }
        XCTAssertEqual(others.map(\.canonical), ["c", "a", "b"])
    }
}
