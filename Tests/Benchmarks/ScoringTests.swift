import Testing
@testable import Scoring

@Suite("WER")
struct WERTests {
    @Test func normalizationIsDocumentedAndStable() {
        #expect(WER.normalize("Um, it's the Q3 [laughter] road-map — OK?") == ["it's", "the", "q3", "road", "map", "ok"])
        #expect(WER.normalize("Don’t") == ["don't"])
        #expect(WER.normalize("ship 15 units on the 3rd, 120 total, 2000") ==
                ["ship", "fifteen", "units", "on", "the", "third", "one", "hundred", "twenty", "total", "two", "thousand"])
        #expect(WER.score(reference: "fifteen percent", hypothesis: "15 percent").errors == 0)
    }

    @Test func countsEachErrorKind() {
        // Minimal edit distance is 3 here; several alignments tie, so only the total is well defined.
        let r = WER.score(reference: "the cat sat on the mat", hypothesis: "the cat sit on mat today")
        #expect(r.referenceWords == 6 && r.errors == 3)
        #expect(abs(r.wer - 0.5) < 1e-9)
        // Unambiguous cases for each kind.
        let s = WER.score(reference: "a b c d", hypothesis: "a x c d e")
        #expect(s.substitutions == 1 && s.insertions == 1 && s.deletions == 0)
        let d = WER.score(reference: "a b c", hypothesis: "a c")
        #expect(d.deletions == 1 && d.substitutions == 0 && d.insertions == 0)
    }

    @Test func emptyCases() {
        #expect(WER.score(reference: "", hypothesis: "").wer == 0)
        #expect(WER.score(reference: "", hypothesis: "hello").wer == 1)
        #expect(WER.score(reference: "a b", hypothesis: "").deletions == 2)
    }

    @Test func numberErrorsReportedSeparately() {
        // Formatting differences are normalized away (v2)...
        let same = WER.score(reference: "ship on thursday the 14th with 3 builds", hypothesis: "ship on thursday the fourteenth with three builds")
        #expect(same.errors == 0)
        // ...while real number errors are still counted and reported separately.
        let r = WER.score(reference: "ship three builds on the fourteenth", hypothesis: "ship four builds on the fifteenth")
        #expect(r.numberTokens == 2 && r.numberTokenErrors == 2)
    }

    @Test func aggregation() {
        let a = WER.score(reference: "a b c", hypothesis: "a b"), b = WER.score(reference: "d e", hypothesis: "d x")
        let t = a + b
        #expect(t.referenceWords == 5 && t.errors == 2)
    }
}

@Suite("DER")
struct DERTests {
    typealias S = DER.Segment

    @Test func perfectHypothesisWithDifferentLabelsScoresZero() {
        let ref = [S(start: 0, end: 5, speaker: "A"), S(start: 5, end: 10, speaker: "B")]
        let hyp = [S(start: 0, end: 5, speaker: "spk1"), S(start: 5, end: 10, speaker: "spk0")]
        let r = DER.score(reference: ref, hypothesis: hyp)
        #expect(r.der < 1e-9)
        #expect(r.mapping == ["spk1": "A", "spk0": "B"])
    }

    @Test func separatesMissFalseAlarmConfusion() {
        let ref = [S(start: 0, end: 10, speaker: "A"), S(start: 10, end: 20, speaker: "B")]
        // 0–8 A correct, 8–10 missed, 10–15 labelled A (confusion), 15–20 B correct, 20–22 false alarm.
        let hyp = [S(start: 0, end: 8, speaker: "x"), S(start: 10, end: 15, speaker: "x"), S(start: 15, end: 20, speaker: "y"),
                   S(start: 20, end: 22, speaker: "y")]
        let r = DER.score(reference: ref, hypothesis: hyp)
        #expect(abs(r.referenceSpeech - 20) < 0.02)
        #expect(abs(r.missed - 2) < 0.02)
        #expect(abs(r.falseAlarm - 2) < 0.02)
        #expect(abs(r.confusion - 5) < 0.02)
        #expect(abs(r.der - 9.0 / 20) < 0.002)
    }

    @Test func overlapIsScoredPerSpeaker() {
        let ref = [S(start: 0, end: 10, speaker: "A"), S(start: 5, end: 10, speaker: "B")]
        let hyp = [S(start: 0, end: 10, speaker: "x")] // never detects the overlapping B
        let r = DER.score(reference: ref, hypothesis: hyp)
        #expect(abs(r.referenceSpeech - 15) < 0.02)
        #expect(abs(r.missed - 5) < 0.02)
    }

    @Test func unknownCountsAsMissedAttribution() {
        let ref = [S(start: 0, end: 10, speaker: "A")]
        let hyp = [S(start: 0, end: 10, speaker: DER.unknownLabel)]
        #expect(abs(DER.score(reference: ref, hypothesis: hyp).der - 1) < 1e-6)
    }

    @Test func uemRestrictsScoringRegion() {
        let ref = [S(start: 0, end: 10, speaker: "A")]
        let hyp = [S(start: 0, end: 5, speaker: "x")]
        let r = DER.score(reference: ref, hypothesis: hyp, uem: [(0, 5)])
        #expect(r.der < 1e-6)
    }

    @Test func rttmParsing() {
        let text = "SPEAKER ES2004a 1 3.34 1.25 <NA> <NA> MEE013 <NA> <NA>\nSPEAKER other 1 0 1 <NA> <NA> X <NA> <NA>\n"
        let s = DER.parseRTTM(text, file: "ES2004a")
        #expect(s == [S(start: 3.34, end: 4.59, speaker: "MEE013")])
    }

    @Test func hungarianPicksGlobalOptimumNotGreedy() {
        // Greedy would pair (0,0)=9 then (1,1)=1 → 10; optimum is (0,1)+(1,0) = 8+8 = 16.
        let pairs = Hungarian.maximize([[9, 8], [8, 1]])
        #expect(Set(pairs.map { "\($0.0)-\($0.1)" }) == ["0-1", "1-0"])
    }
}
