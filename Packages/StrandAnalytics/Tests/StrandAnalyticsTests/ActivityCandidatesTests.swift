import XCTest
@testable import StrandAnalytics

final class ActivityCandidatesTests: XCTestCase {
    typealias A = ActivityCandidates

    /// A day of minutes from 08:00, resting at 65 bpm with no steps, with injected stretches.
    private func day(_ count: Int = 600, base: Int = 1_000_000_020,
                     _ shape: (Int) -> (bpm: Double?, steps: Int?, walk: Int?, run: Int?, classed: Int?)) -> [A.Minute] {
        (0..<count).map { i in
            let s = shape(i)
            return A.Minute(ts: base + i * 60, bpm: s.bpm, steps: s.steps, walkSeconds: s.walk, runSeconds: s.run,
                            classSeconds: s.classed, asleep: false)
        }
    }
    private let still: (bpm: Double?, steps: Int?, walk: Int?, run: Int?, classed: Int?) = (65, 0, 0, 0, 60)
    private func walking(_ bpm: Double = 100) -> (bpm: Double?, steps: Int?, walk: Int?, run: Int?, classed: Int?) {
        (bpm, 105, 60, 0, 60)
    }

    func testTheWalkTrackFindsSeveralWalksOfDifferentLengthsAndToleratesARedLight() {
        let minutes = day { i in
            switch i {
            case 60..<95: return i == 70 || i == 71 ? self.still : self.walking()   // 35 min, a two-minute stop
            case 200..<220: return self.walking()                                   // 20 min
            case 300..<310: return self.walking()                                   // 10 min, too short
            default: return self.still
            }
        }
        let walks = A.walkCandidates(minutes, hrMax: 180)
        XCTAssertEqual(walks.map(\.durationMinutes), [35, 20])
        XCTAssertEqual(walks.first?.kinds, [.walk])
        XCTAssertEqual(walks.first?.cadence, 105)
    }

    private let slowing: (bpm: Double?, steps: Int?, walk: Int?, run: Int?, classed: Int?) = (95, 55, 40, 0, 60)

    func testARedLightDoesNotEndAWalkEvenWhenItTouchesSeveralClockMinutes() {
        // Two minutes at a light: a half minute of walking, three still minutes, a half minute of walking.
        let minutes = day { i in
            switch i {
            case 100: return (95, 80, 60, 0, 60)
            case 101..<130, 135..<165: return self.walking()
            case 130, 134: return self.slowing
            case 131..<134: return self.still
            default: return self.still
            }
        }
        XCTAssertEqual(A.walkCandidates(minutes, hrMax: 180).map(\.durationMinutes), [65])
    }

    func testAStopEarlyInAWalkKeepsTheMinutesBeforeIt() {
        let minutes = day { i in
            switch i {
            case 100..<105, 107..<127: return self.walking()
            default: return self.still
            }
        }
        let walks = A.walkCandidates(minutes, hrMax: 180)
        XCTAssertEqual(walks.map(\.durationMinutes), [27])
        XCTAssertEqual(walks.first?.start, minutes[100].ts)
    }

    func testTwoStretchesTooShortAloneAreOneWalkAcrossALight() {
        let minutes = day { i in
            switch i {
            case 100..<112, 116..<128: return self.walking()
            default: return self.still
            }
        }
        XCTAssertEqual(A.walkCandidates(minutes, hrMax: 180).map(\.durationMinutes), [28])
    }

    func testSlowerMinutesKeepAWalkGoingButNeverMakeOne() {
        let slowerStretch = day { i in
            switch i {
            case 100..<120, 128..<148: return self.walking()
            case 120..<128: return self.slowing
            default: return self.still
            }
        }
        XCTAssertEqual(A.walkCandidates(slowerStretch, hrMax: 180).map(\.durationMinutes), [48])
        let onlySlow = day { i in (100..<160).contains(i) ? self.slowing : self.still }
        XCTAssertTrue(A.walkCandidates(onlySlow, hrMax: 180).isEmpty)
    }

    func testALongStopAndAStopAndGoAfternoonStayApart() {
        let longStop = day { i in
            switch i {
            case 100..<120, 126..<146: return self.walking()
            default: return self.still
            }
        }
        XCTAssertEqual(A.walkCandidates(longStop, hrMax: 180).map(\.durationMinutes), [20, 20],
                       "six still minutes are a rest, not a light")
        // Three minutes on, four off, for two hours: never half of the time on foot.
        let errands = day { i in (100..<220).contains(i) && (i - 100) % 7 < 3 ? self.walking() : self.still }
        XCTAssertTrue(A.walkCandidates(errands, hrMax: 180).isEmpty)
    }

    func testAHoleInTheDataCountsAsStandingStill() {
        let all = day { i in
            switch i {
            case 100..<120, 124..<144, 200..<220, 230..<250: return self.walking()
            default: return self.still
            }
        }
        let holes = all.enumerated().filter { !(120..<124 ~= $0.offset) && !(220..<230 ~= $0.offset) }.map(\.element)
        XCTAssertEqual(A.walkCandidates(holes, hrMax: 180).map(\.durationMinutes), [44, 20, 20])
    }

    func testAWalkTakesTheSlowerMinutesAroundIt() {
        let minutes = day { i in
            switch i {
            case 100..<103, 104..<107: return self.slowing          // setting off, one minute standing inside
            case 107..<130: return self.walking()
            case 130..<133: return self.slowing                     // arriving
            default: return self.still
            }
        }
        let walks = A.walkCandidates(minutes, hrMax: 180)
        XCTAssertEqual(walks.first?.start, minutes[100].ts)
        XCTAssertEqual(walks.first?.end, minutes[133].ts)
    }

    func testTheEdgesStopAtTwoStillMinutesAtTheirLimitAndAtTheNextWalk() {
        let gap = day { i in
            switch i {
            case 100..<105, 107..<110: return self.slowing
            case 110..<130: return self.walking()
            default: return self.still
            }
        }
        XCTAssertEqual(A.walkCandidates(gap, hrMax: 180).first?.start, gap[107].ts, "two still minutes end the edge")
        let long = day { i in
            switch i {
            case 80..<110: return self.slowing
            case 110..<130: return self.walking()
            default: return self.still
            }
        }
        XCTAssertEqual(A.walkCandidates(long, hrMax: 180).first?.start, long[100].ts, "ten minutes at most")
        let neighbours = day { i in
            switch i {
            case 100..<120, 130..<150: return self.walking()
            case 120, 121, 128, 129: return self.slowing
            default: return self.still
            }
        }
        let two = A.walkCandidates(neighbours, hrMax: 180)
        XCTAssertEqual(two.map(\.start), [neighbours[100].ts, neighbours[128].ts])
        XCTAssertEqual(two.first?.end, neighbours[122].ts)
    }

    func testSlowMinutesAloneDoNotMakeAStretchLongEnough() {
        // Ten full minutes with eight slower ones around them are pottering about, not a walk.
        let minutes = day { i in
            switch i {
            case 100..<104, 114..<118: return self.slowing
            case 104..<114: return self.walking()
            default: return self.still
            }
        }
        XCTAssertTrue(A.walkCandidates(minutes, hrMax: 180).isEmpty)
    }

    func testAMixedWayIsAskedAboutWithoutTheLoadExceptAtOnlyClear() {
        // Walking, six minutes in a shop or on a tram, walking: too short for the walk track either side.
        let minutes = day { i in
            switch i {
            case 100..<103: return (90, 60, 40, 0, 60)                       // setting off
            case 103..<110: return (125, 100, 60, 0, 60)
            case 110..<116: return (112, 3, 0, 0, 60)
            case 116..<124: return (130, 100, 60, 0, 60)
            default: return self.still
            }
        }
        let all = A.candidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: 0.1)
        XCTAssertEqual(all.map(\.track), [.heartRate])
        let way = all[0]
        XCTAssertEqual(way.start, minutes[100].ts, "the slower minutes before the heart rate rose belong to it")
        XCTAssertEqual(way.end, minutes[124].ts)
        XCTAssertLessThan(way.load, A.Level.more.minimumLoad)
        XCTAssertEqual(way.kinds.first, .walk)
        XCTAssertTrue(way.asks(at: .more))
        XCTAssertTrue(way.asks(at: .balanced))
        XCTAssertFalse(way.asks(at: .onlyClear))
    }

    func testAHeartRateSpanThatWasNotMostlyWalkingKeepsItsSpanAndItsLoadGate() {
        let minutes = day { i in
            switch i {
            case 95..<100: return (70, 55, 40, 0, 60)
            case 100..<120: return (125, 4, 0, 0, 60)
            default: return self.still
            }
        }
        let hr = A.heartRateCandidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: 0.1)
        XCTAssertEqual(hr.first?.start, minutes[100].ts)
        XCTAssertFalse(hr.first!.asks(at: .balanced))
    }

    func testAMixedWayDoesNotGrowIntoAWalkBesideIt() {
        let minutes = day { i in
            switch i {
            case 100..<120: return self.walking()
            case 120..<124: return (125, 60, 40, 0, 60)
            case 124..<140: return (125, 90, 35, 0, 60)
            default: return self.still
            }
        }
        let all = A.candidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: 0.1)
        for pair in zip(all, all.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.end, pair.1.start) }
    }

    func testARunIsNamedARun() {
        let minutes = day { i in (60..<90).contains(i) ? (150, 165, 5, 55, 60) : self.still }
        XCTAssertEqual(A.walkCandidates(minutes, hrMax: 185).first?.kinds, [.run])
    }

    func testAWhoop4WithoutAStepStreamFindsNoWalkButStillAHeartRateSpan() {
        let minutes = day { i in (100..<140).contains(i) ? (140, nil, nil, nil, nil) : (65, nil, nil, nil, nil) }
        XCTAssertTrue(A.walkCandidates(minutes, hrMax: 180).isEmpty)
        let hr = A.heartRateCandidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: nil)
        XCTAssertEqual(hr.map(\.durationMinutes), [40])
        XCTAssertNil(hr.first?.cadence)
        XCTAssertNil(hr.first?.locomotionShare)
        XCTAssertEqual(hr.first?.kinds, [.strength, .cycle, .other])
    }

    func testTheHeartRateBarIsPersonal() {
        // The same 120 bpm stretch is above the bar of someone whose everyday level is low and below the
        // bar of someone who is often around 120 anyway.
        let minutes = day { i in (100..<140).contains(i) ? (120, 0, 0, 0, 60) : self.still }
        let calm = A.heartRateCandidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: 0.15)
        let busy = A.heartRateCandidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: 0.45)
        XCTAssertEqual(calm.count, 1)
        XCTAssertTrue(busy.isEmpty)
    }

    func testTheEverydayLevelUsesOnlyAwakeHistoryAndNeedsEnoughOfIt() {
        let short = day(100) { _ in self.still }
        XCTAssertNil(A.everydayHRR(history: short, restingHR: 55, hrMax: 180))
        let history = day(3_000) { i in i % 4 == 0 ? (100, 0, 0, 0, 60) : self.still }
        let level = A.everydayHRR(history: history, restingHR: 55, hrMax: 180)!
        XCTAssertEqual(level, (65.0 - 55) / 125, accuracy: 1e-9, "the 75th percentile is the resting minutes")
        let asleep = history.map { A.Minute(ts: $0.ts, bpm: 200, steps: 0, walkSeconds: 0, runSeconds: 0,
                                            classSeconds: 60, asleep: true) }
        XCTAssertNil(A.everydayHRR(history: asleep, restingHR: 55, hrMax: 180))
    }

    func testStrengthSetsWithRestsBecomeOneSpan() {
        // Six 6-minute blocks of work with 5-minute rests: each block is too short alone.
        let minutes = day { i in
            let t = i - 100
            guard t >= 0, t < 66 else { return self.still }
            return t % 11 < 6 ? (130, 2, 0, 0, 60) : (70, 0, 0, 0, 60)
        }
        let hr = A.heartRateCandidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: 0.1)
        XCTAssertEqual(hr.map(\.durationMinutes), [61], "six short blocks with rests are one session")
        let longer = day { i in
            let t = i - 100
            guard t >= 0, t < 80 else { return self.still }
            return t < 20 || (t >= 28 && t < 50) ? (130, 2, 0, 0, 60) : (70, 0, 0, 0, 60)
        }
        let joined = A.heartRateCandidates(longer, restingHR: 55, hrMax: 180, everydayHRR: 0.1)
        XCTAssertEqual(joined.count, 1, "two spans eight minutes apart are one session")
        XCTAssertEqual(joined.first?.durationMinutes, 50)
    }

    func testTheWayToTheGymIsCutOutOfTheSession() {
        // Walk 20 min, lift 40 min, walk 20 min: one walk, one session, one walk.
        let minutes = day { i in
            switch i {
            case 100..<120, 160..<180: return self.walking(115)
            case 120..<160: return (135, 1, 0, 0, 60)
            default: return self.still
            }
        }
        let all = A.candidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: 0.1)
        XCTAssertEqual(all.map(\.track), [.walk, .heartRate, .walk])
        XCTAssertEqual(all.map(\.durationMinutes), [20, 40, 20])
        XCTAssertEqual(all[1].kinds.first, .strength)
    }

    func testAWalkIsNotAskedAboutTwice() {
        let minutes = day { i in (60..<100).contains(i) ? self.walking(125) : self.still }
        let all = A.candidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: 0.1)
        XCTAssertEqual(all.map(\.track), [.walk])
    }

    func testEdwardsLoadAndTheLevelsGateOnlyHeartRateSpans() {
        let minutes = day(30) { i in i < 10 ? (95, 0, 0, 0, 60) : i < 20 ? (130, 0, 0, 0, 60) : (165, 0, 0, 0, 60) }
        // 95/180 = 53 % → 1, 130/180 = 72 % → 3, 165/180 = 92 % → 5.
        XCTAssertEqual(A.edwardsLoad(minutes, hrMax: 180), 90)
        let hr = A.Candidate(track: .heartRate, start: 0, end: 1_800, avgBpm: 130, peakBpm: 165, load: 90,
                             cadence: nil, locomotionShare: nil, kinds: [.strength])
        XCTAssertTrue(hr.asks(at: .more))
        XCTAssertTrue(hr.asks(at: .balanced))
        XCTAssertFalse(hr.asks(at: .onlyClear))
        let walk = A.Candidate(track: .walk, start: 0, end: 1_800, avgBpm: 95, peakBpm: 100, load: 10,
                               cadence: 100, locomotionShare: 1, kinds: [.walk])
        XCTAssertTrue(walk.asks(at: .onlyClear))
    }

    func testSleepNeverStartsASpan() {
        let minutes = (0..<600).map { i in
            A.Minute(ts: 1_000_000_020 + i * 60, bpm: (100..<140).contains(i) ? 140 : 65, steps: 0, walkSeconds: 0,
                     runSeconds: 0, classSeconds: 60, asleep: true)
        }
        XCTAssertTrue(A.heartRateCandidates(minutes, restingHR: 55, hrMax: 180, everydayHRR: nil).isEmpty)
    }
}
