import Testing
@testable import Scoring

@Suite("G5 perf guard")
struct PerfGuardTests {
    static let baseline = PerfGuard.Quality(
        sets: ["ami-clean": .init(wer: 0.200, der: 0.250, labelled: 0.90, correct: 0.80, failedSeconds: 40),
               "librispeech": .init(wer: 0.025, failedSeconds: 0)],
        controlWords: ["silence": 0, "noise": 0, "music": 0], boundaryFailures: [],
        notes: .init(itemsWithValidEvidence: 50, items: 50, plantedFound: 8, plantedExpected: 8, injectionsPassed: 10, injections: 10, uncertain: 10))

    @Test func identicalRunPasses() {
        #expect(PerfGuard.evaluate(baseline: Self.baseline, current: Self.baseline).isEmpty)
        #expect(PerfGuard.notChecked(baseline: Self.baseline, current: Self.baseline).isEmpty)
    }

    @Test func changesWithinBoundsPass() {
        var c = Self.baseline
        c.sets["ami-clean"] = .init(wer: 0.209, der: 0.269, labelled: 0.891, correct: 0.791, failedSeconds: 49)
        c.notes?.uncertain = 12   // 24% vs 20%: +4 points
        #expect(PerfGuard.evaluate(baseline: Self.baseline, current: c).isEmpty)
    }

    @Test func injectedRegressionsAreBreaches() {
        var c = Self.baseline
        c.sets["ami-clean"] = .init(wer: 0.215, der: 0.275, labelled: 0.88, correct: 0.78, failedSeconds: 51)
        c.sets["librispeech"]?.wer = 0.036
        c.controlWords["music"] = 3
        c.boundaryFailures = ["negation 'not' count 3 → 2"]
        c.notes = .init(itemsWithValidEvidence: 49, items: 50, plantedFound: 7, plantedExpected: 8, injectionsPassed: 9, injections: 10, uncertain: 13)
        c.failedItems = ["ami-EN2002a-mix"]
        let checks = Set(PerfGuard.evaluate(baseline: Self.baseline, current: c).map(\.check))
        #expect(checks == ["completed", "wer:ami-clean", "wer:librispeech", "der:ami-clean", "labelled:ami-clean", "correct:ami-clean",
                           "failedCoverage:ami-clean", "control:music", "boundary", "notes:evidence", "notes:planted", "notes:injection",
                           "notes:uncertain"])
    }

    @Test func smallFailedCoverageBaselinesGetAbsoluteSlack() {
        var c = Self.baseline
        c.sets["librispeech"]?.failedSeconds = 1.5   // from 0 s: within the 2 s slack
        #expect(PerfGuard.evaluate(baseline: Self.baseline, current: c).isEmpty)
        c.sets["librispeech"]?.failedSeconds = 2.5
        #expect(PerfGuard.evaluate(baseline: Self.baseline, current: c).map(\.check) == ["failedCoverage:librispeech"])
    }

    @Test func missingSuitesAreReportedAsNotCheckedNotAsPassing() {
        let c = PerfGuard.Quality(sets: ["librispeech": .init(wer: 0.025)])
        #expect(PerfGuard.evaluate(baseline: Self.baseline, current: c).isEmpty)
        #expect(PerfGuard.notChecked(baseline: Self.baseline, current: c)
                == ["set ami-clean", "control music", "control noise", "control silence", "boundary fixtures", "notes checks"])
    }

    @Test func corpusDisagreementIsFlaggedNotABreach() {
        let flags = PerfGuard.corpusFlags(id: "m1", wordAgreement: 0.96, speakerAgreement: 0.95, notesOverlap: 0.5)
        #expect(flags.map(\.check) == ["corpus:words:m1", "corpus:notes:m1"])
        #expect(PerfGuard.corpusFlags(id: "m1", wordAgreement: 0.99, speakerAgreement: 0.95, notesOverlap: 0.8).isEmpty)
    }
}
