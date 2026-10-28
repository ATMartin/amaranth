import Foundation
import Testing
import Domain
@testable import Presentation

@Suite("Meeting status glyph")
struct MeetingStatusGlyphTests {
    /// Every audio headline. The switch fails to compile when a case is added, so this list cannot fall behind.
    static let audio: [MeetingStatus.AudioHeadline] = {
        let all: [MeetingStatus.AudioHeadline] = [.notStarted, .recording, .paused, .saving, .saved, .savedWithGaps(missingSeconds: 2450),
                                                  .interrupted, .audioDeleted]
        for a in all { switch a { case .notStarted, .recording, .paused, .saving, .saved, .savedWithGaps, .interrupted, .audioDeleted: break } }
        return all
    }()

    /// Every processing headline, with every stage and suspension reason.
    static let processing: [MeetingStatus.ProcessingHeadline] = {
        let reasons: [SuspensionReason?] = [nil, .recordingActive, .thermalPressure, .memoryPressure, .userPaused, .captureFault]
        for r in reasons { switch r { case nil, .recordingActive, .thermalPressure, .memoryPressure, .userPaused, .captureFault: break } }
        var all: [MeetingStatus.ProcessingHeadline] = [.notQueued, .complete] + reasons.map { .waiting($0) }
        for stage in ProcessingStage.allCases { all += [.running(stage, progress: 0.42), .failed(stage, errorCode: "E1"), .cancelled(stage)] }
        for p in all { switch p { case .notQueued, .waiting, .running, .complete, .failed, .cancelled: break } }
        return all
    }()

    static func status(_ a: MeetingStatus.AudioHeadline, _ p: MeetingStatus.ProcessingHeadline) -> MeetingStatus {
        var s = MeetingStatus(meeting: Meeting(id: MeetingID("m"), title: "t", createdAt: Date(), captureState: .captured, duration: .seconds(60)),
                              jobs: [], events: [])
        s.audio = a; s.processing = p
        return s
    }

    @Test func everyCombinationHasExactlyOneGlyphAndATooltip() {
        for a in Self.audio {
            for p in Self.processing {
                let g = MeetingStatusPresentation.glyph(Self.status(a, p))
                #expect((g.symbol != nil) != g.spinner, "\(a) / \(p): one symbol or one spinner")
                #expect(!g.tooltip.isEmpty, "\(a) / \(p): tooltip")
            }
        }
    }

    @Test func keyStatesMatchTheDesign() {
        func g(_ a: MeetingStatus.AudioHeadline, _ p: MeetingStatus.ProcessingHeadline) -> MeetingStatusPresentation.Glyph {
            MeetingStatusPresentation.glyph(Self.status(a, p))
        }
        #expect(g(.recording, .waiting(.recordingActive)).symbol == "record.circle" && g(.recording, .notQueued).tone == .red)
        #expect(g(.saved, .complete) == .init(symbol: "checkmark.circle", spinner: false, tone: .secondary, tooltip: "Processed · audio saved"))
        #expect(g(.savedWithGaps(missingSeconds: 2450), .complete).tooltip == "Processed · 2,450 s of audio missing — see Recording tab")
        #expect(g(.saved, .failed(.transcribe, errorCode: nil)).tooltip == "Transcribing failed — retry available")
        #expect(g(.saved, .running(.diarize, progress: 0.5)).spinner && g(.saved, .waiting(nil)).spinner)
        #expect(g(.saved, .waiting(.thermalPressure)).symbol == "hourglass")
        #expect(g(.audioDeleted, .complete).tooltip == "Audio deleted; transcript and notes kept")
        #expect(g(.saved, .notQueued).symbol == "circle.dashed" && g(.saved, .cancelled(.notes)).symbol == "stop.circle")
        #expect(g(.paused, .notQueued).symbol == "pause.circle" && g(.saving, .notQueued).symbol == "arrow.down.circle")
    }

    /// T80: cards show a spinner while saving or processing and a mark when processing failed; nothing otherwise.
    @Test func cardsShowOnlyProgressAndFailure() {
        for a in Self.audio {
            for p in Self.processing {
                let c = MeetingStatusPresentation.cardGlyph(Self.status(a, p))
                let expected: String
                switch (a, p) {
                case (.recording, _), (.paused, _): expected = "none"
                case (.saving, _), (_, .running), (_, .waiting): expected = "spinner"
                case (_, .failed): expected = "failed"
                default: expected = "none"
                }
                let got = c == nil ? "none" : c!.spinner ? "spinner" : c!.symbol == "exclamationmark.triangle" && c!.tone == .red ? "failed" : "other"
                #expect(got == expected, "\(a) / \(p): \(got)")
                if let c { #expect(!c.tooltip.isEmpty) }
            }
        }
        let failed = MeetingStatusPresentation.cardGlyph(Self.status(.saved, .failed(.notes, errorCode: nil)))
        #expect(failed?.tooltip == "Writing notes failed — retry available")
        #expect(MeetingStatusPresentation.cardGlyph(Self.status(.saved, .complete)) == nil)
        #expect(MeetingStatusPresentation.cardGlyph(Self.status(.savedWithGaps(missingSeconds: 3), .complete)) == nil)
    }
}
