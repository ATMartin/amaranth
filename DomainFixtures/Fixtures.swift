public import Foundation
public import Domain

/// A complete deterministic meeting: every ID, time and date is fixed so round trips and UI snapshots are stable.
public struct FixtureMeeting: Sendable, Codable, Hashable {
    public var name: String
    public var meeting: Meeting
    public var epochs: [CaptureEpoch]
    public var audioSegments: [AudioSegmentRecord]
    public var events: [CaptureEvent]
    public var transcript: TranscriptRevision?
    public var diarization: [DiarizationResult]
    public var edits: [UserEdit]
    public var summary: SummaryRevision?
    public var scratchpad: ScratchpadRevision?
    public var jobs: [ProcessingJob]

    public var status: MeetingStatus { MeetingStatus(meeting: meeting, jobs: jobs, events: events) }

    public init(name: String, meeting: Meeting, epochs: [CaptureEpoch], audioSegments: [AudioSegmentRecord], events: [CaptureEvent],
                transcript: TranscriptRevision?, diarization: [DiarizationResult], edits: [UserEdit], summary: SummaryRevision?,
                scratchpad: ScratchpadRevision?, jobs: [ProcessingJob]) {
        self.name = name; self.meeting = meeting; self.epochs = epochs; self.audioSegments = audioSegments; self.events = events
        self.transcript = transcript; self.diarization = diarization; self.edits = edits; self.summary = summary
        self.scratchpad = scratchpad; self.jobs = jobs
    }
}

extension FixtureMeeting: CustomStringConvertible {
    public var description: String { name }
}

public enum Fixtures {
    public static let referenceDate = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-14T…Z, fixed
    static let producerASR = ProducerInfo(component: "fixture-asr", modelManifestID: ModelManifestID("fixture.asr"),
                                          modelVersion: "0", configHash: "cfg-asr-0")
    static let producerDiar = ProducerInfo(component: "fixture-diarizer", configHash: "cfg-diar-0")
    static let producerNotes = ProducerInfo(component: "fixture-notes", configHash: "cfg-notes-0")

    public static var all: [FixtureMeeting] {
        [twoSourceConversation, missingSource, pausedMeeting, staleSummary]
    }

    // MARK: Builders

    /// Builds words with deterministic IDs, spreading them evenly over `interval`.
    static func words(_ text: String, _ interval: SessionInterval, source: SourceKind, prefix: String,
                      speaker: SpeakerAssignment, flags: WordFlags = []) -> [Word] {
        let tokens = text.split(separator: " ").map(String.init)
        let step = interval.duration.nanoseconds / Int64(max(tokens.count, 1))
        return tokens.enumerated().map { i, t in
            let s = interval.start.nanoseconds + Int64(i) * step
            return Word(id: WordID("\(prefix)-w\(i)"), text: t,
                        interval: SessionInterval(unchecked: SessionTime(nanoseconds: s), SessionTime(nanoseconds: s + step)),
                        source: source, quality: ASRQuality(engine: "fixture", values: ["tokenLogProb": -0.1]),
                        speaker: speaker, flags: flags)
        }
    }

    static func segment(_ id: String, _ text: String, _ a: Double, _ b: Double, source: SourceKind,
                        speaker: SpeakerAssignment, flags: WordFlags = []) -> TranscriptSegment {
        let iv = SessionInterval.seconds(a, b)
        return TranscriptSegment(id: TranscriptSegmentID(id), source: source, interval: iv,
                                 words: words(text, iv, source: source, prefix: id, speaker: speaker, flags: flags),
                                 speaker: speaker, flags: flags)
    }

    static func epochs(_ m: MeetingID, starts: [(SessionTime, EpochStartReason)]) -> [CaptureEpoch] {
        var out: [CaptureEpoch] = []
        for src in SourceKind.allCases {
            for (i, (t, reason)) in starts.enumerated() {
                out.append(CaptureEpoch(id: EpochID("\(m)-\(src.rawValue)-e\(i)"), meetingID: m, source: src, index: i,
                                        format: src == .microphone
                                            ? AudioFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32)
                                            : AudioFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32),
                                        sessionStart: t, hostTimeAtFirstFrameNanos: 1_000_000_000 + UInt64(t.nanoseconds),
                                        deviceUID: src == .microphone ? "BuiltInMicrophoneDevice" : "amaranth.tap",
                                        deviceName: src == .microphone ? "MacBook Pro Microphone" : "System Output",
                                        reason: reason))
            }
        }
        return out
    }

    /// Two-second segments for each source over the given covered intervals.
    static func audioSegments(_ m: MeetingID, epochs: [CaptureEpoch], covered: [SourceKind: [SessionInterval]]) -> [AudioSegmentRecord] {
        var out: [AudioSegmentRecord] = []
        for src in SourceKind.allCases {
            var seq: Int64 = 0
            for iv in covered[src] ?? [] {
                guard let epoch = epochs.last(where: { $0.source == src && $0.sessionStart <= iv.start }) else { continue }
                var t = iv.start
                while t < iv.end {
                    let e = min(t + .seconds(2), iv.end)
                    let frames = (e - t).nanoseconds * Int64(epoch.format.sampleRate) / 1_000_000_000
                    let first = (t - epoch.sessionStart).nanoseconds * Int64(epoch.format.sampleRate) / 1_000_000_000
                    out.append(AudioSegmentRecord(
                        id: AudioSegmentID("\(m)-\(src.rawValue)-s\(seq)"), meetingID: m, source: src, epochID: epoch.id,
                        sequence: seq, format: epoch.format, firstFrameInEpoch: first, frameCount: frames,
                        interval: SessionInterval(unchecked: t, e),
                        relativePath: "\(src.rawValue)/\(String(format: "%04lld", t.nanoseconds / 60_000_000_000))/\(String(format: "%08lld", seq)).caf",
                        sha256: String(repeating: "0", count: 64), state: .committed))
                    seq += 1
                    t = e
                }
            }
        }
        return out
    }

    static func job(_ m: MeetingID, _ stage: ProcessingStage, _ state: ProcessingState, error: String? = nil,
                    progress: Double = 1, suspension: SuspensionReason? = nil) -> ProcessingJob {
        ProcessingJob(id: JobID("\(m)-\(stage.rawValue)"),
                      key: JobKey(meetingID: m, stage: stage, inputHash: "in-\(stage.rawValue)", configHash: "cfg"),
                      state: state, suspension: suspension, attempt: state == .queued ? 0 : 1, progress: progress,
                      errorCode: error, createdAt: referenceDate, updatedAt: referenceDate)
    }

    static func evidence(_ rev: RevisionID, _ seg: TranscriptSegment, _ a: Int, _ b: Int) -> EvidenceRef {
        .transcript(TranscriptEvidence(revisionID: rev, segmentID: seg.id, firstWord: seg.words[a].id, lastWord: seg.words[b].id))
    }

    // MARK: Scenarios

    /// Mic (one local speaker) + system output (two remote speakers), with an overlap,
    /// an unknown short acknowledgement, a decision with a supported owner and an action item with a null owner.
    public static var twoSourceConversation: FixtureMeeting {
        let m = MeetingID("fx-two-source")
        let rev = RevisionID("fx-two-source-r1")
        let diarRun = RevisionID("fx-two-source-d1")
        let me = Speaker(id: SpeakerID("spk-1"), label: "Speaker 1",
                         clusters: [ClusterRef(diarizationRunID: diarRun, cluster: ClusterID("mic-0"))], primarySource: .microphone)
        let s2 = Speaker(id: SpeakerID("spk-2"), label: "Speaker 2",
                         clusters: [ClusterRef(diarizationRunID: diarRun, cluster: ClusterID("sys-0"))], primarySource: .systemOutput)
        let s3 = Speaker(id: SpeakerID("spk-3"), label: "Speaker 3",
                         clusters: [ClusterRef(diarizationRunID: diarRun, cluster: ClusterID("sys-1"))], primarySource: .systemOutput)

        let segs = [
            segment("g0", "Thanks for joining let's review the launch checklist", 1, 5, source: .microphone, speaker: .speaker(me.id)),
            segment("g1", "Sure the build is green and the installer is signed", 5.5, 10, source: .systemOutput, speaker: .speaker(s2.id)),
            // Overlap: speaker 3 interrupts while speaker 2 still talks.
            segment("g2", "wait the notarization step is not done", 9, 12, source: .systemOutput,
                    speaker: .multiple([s2.id, s3.id]), flags: [.overlap, .uncertainSpeaker]),
            segment("g3", "Okay then we will ship on Thursday not Wednesday", 12.5, 17, source: .microphone, speaker: .speaker(me.id)),
            segment("g4", "mm-hmm", 17.2, 17.6, source: .systemOutput, speaker: .unknown, flags: [.uncertainSpeaker]),
            segment("g5", "Someone needs to update the release notes", 18, 21, source: .systemOutput, speaker: .speaker(s3.id)),
            segment("g6", "Dana will finish notarization by Wednesday", 21.5, 25, source: .systemOutput, speaker: .speaker(s2.id)),
        ]
        let duration = SessionTime.seconds(26)
        let eps = epochs(m, starts: [(.zero, .sessionStart)])
        let full = SessionInterval(unchecked: .zero, duration)
        let transcript = TranscriptRevision(
            id: rev, meetingID: m, kind: .final, stage: .attributed, createdAt: referenceDate, producer: producerASR,
            segments: segs,
            coverage: [CoverageRegion(source: .microphone, interval: full, status: .transcribed),
                       CoverageRegion(source: .systemOutput, interval: full, status: .transcribed)],
            speakers: [me, s2, s3])

        let diar = DiarizationResult(
            id: diarRun, meetingID: m, source: .systemOutput, producer: producerDiar,
            clusters: [ClusterID("sys-0"), ClusterID("sys-1")],
            turns: [SpeakerTurn(interval: .seconds(5.5, 12), source: .systemOutput, cluster: ClusterID("sys-0")),
                    SpeakerTurn(interval: .seconds(9, 12), source: .systemOutput, cluster: ClusterID("sys-1")),
                    SpeakerTurn(interval: .seconds(18, 21), source: .systemOutput, cluster: ClusterID("sys-1")),
                    SpeakerTurn(interval: .seconds(21.5, 25), source: .systemOutput, cluster: ClusterID("sys-0"))],
            overlaps: [.seconds(9, 12)])

        let summary = SummaryRevision(
            id: RevisionID("fx-two-source-n1"), meetingID: m, transcriptRevisionID: rev, editSequence: 0,
            createdAt: referenceDate, producer: producerNotes, promptVersion: "notes-v1",
            content: SummaryContent(
                overview: [SummaryItem(id: SummaryItemID("n-ov"), kind: .overview,
                                       text: "Launch checklist review; notarization is outstanding.",
                                       evidence: [evidence(rev, segs[0], 0, 7), evidence(rev, segs[2], 0, 6)])],
                decisions: [SummaryItem(id: SummaryItemID("n-d1"), kind: .decision, text: "Ship on Thursday, not Wednesday.",
                                        evidence: [evidence(rev, segs[3], 0, 8)])],
                actionItems: [
                    SummaryItem(id: SummaryItemID("n-a1"), kind: .actionItem, text: "Update the release notes.",
                                evidence: [evidence(rev, segs[5], 0, 6)], owner: nil),
                    SummaryItem(id: SummaryItemID("n-a2"), kind: .actionItem, text: "Finish notarization.",
                                evidence: [evidence(rev, segs[6], 0, 5)], owner: "Dana",
                                ownerEvidence: [evidence(rev, segs[6], 0, 0)], due: DueDate(originalText: "by Wednesday")),
                ],
                openQuestions: [],
                limitations: [SummaryItem(id: SummaryItemID("n-l1"), kind: .limitation,
                                          text: "One overlapping passage has uncertain speaker attribution.", evidence: [])]),
            validation: SummaryValidationReport(status: .valid))

        return FixtureMeeting(
            name: "Two-source conversation",
            meeting: Meeting(id: m, title: "Launch checklist", createdAt: referenceDate,
                             clock: SessionClock(utcOrigin: referenceDate, timeZoneIdentifier: "America/Los_Angeles", hostTimeOriginNanos: 1_000_000_000),
                             captureState: .captured, selectedSources: .both, duration: duration - .zero,
                             currentTranscriptRevisionID: rev, currentSummaryRevisionID: summary.id),
            epochs: eps,
            audioSegments: audioSegments(m, epochs: eps, covered: [.microphone: [full], .systemOutput: [full]]),
            events: [], transcript: transcript, diarization: [diar], edits: [], summary: summary,
            scratchpad: ScratchpadRevision(id: RevisionID("fx-two-source-p1"), meetingID: m,
                                           text: "ask about notarization creds", includeInSummary: false, createdAt: referenceDate),
            jobs: ProcessingStage.allCases.filter { $0 != .live }.map { job(m, $0, .succeeded) })
    }

    /// System source faults for 15 s mid-meeting. The gap is explicit and transcript coverage marks it
    /// as missing audio, not silence. Notes failed, but audio is saved.
    public static var missingSource: FixtureMeeting {
        let m = MeetingID("fx-missing-source")
        let rev = RevisionID("fx-missing-source-r1")
        let duration = SessionTime.seconds(60)
        let eps = epochs(m, starts: [(.zero, .sessionStart)])
        let gap = SessionInterval.seconds(20, 35)
        let unknownCov: [CoverageRegion] = [
            CoverageRegion(source: .microphone, interval: .seconds(0, 60), status: .transcribed),
            CoverageRegion(source: .systemOutput, interval: .seconds(0, 20), status: .transcribed),
            CoverageRegion(source: .systemOutput, interval: gap, status: .missingAudio),
            CoverageRegion(source: .systemOutput, interval: .seconds(35, 60), status: .transcribed),
        ]
        let segs = [
            segment("m0", "Can everyone hear me", 2, 4, source: .microphone, speaker: .unknown),
            segment("m1", "Yes loud and clear", 5, 7, source: .systemOutput, speaker: .unknown),
            segment("m2", "I think the remote audio dropped", 36, 39, source: .microphone, speaker: .unknown),
        ]
        let transcript = TranscriptRevision(id: rev, meetingID: m, kind: .final, stage: .asr, createdAt: referenceDate,
                                            producer: producerASR, segments: segs, coverage: unknownCov)
        return FixtureMeeting(
            name: "Missing source",
            meeting: Meeting(id: m, title: "Dropped system audio", createdAt: referenceDate,
                             clock: SessionClock(utcOrigin: referenceDate, timeZoneIdentifier: "UTC", hostTimeOriginNanos: 1_000_000_000),
                             captureState: .capturedWithGaps, duration: duration - .zero, currentTranscriptRevisionID: rev),
            epochs: eps,
            audioSegments: audioSegments(m, epochs: eps, covered: [.microphone: [.seconds(0, 60)],
                                                                    .systemOutput: [.seconds(0, 20), .seconds(35, 60)]]),
            events: [
                CaptureEvent(id: CaptureEventID("fx-ms-ev1"), meetingID: m, source: .systemOutput, interval: gap,
                             kind: .sourceFault, reasonCode: "tap.callbacksStalled", recoverable: true, lostFrames: 720_000),
                CaptureEvent(id: CaptureEventID("fx-ms-ev2"), meetingID: m, source: .systemOutput,
                             interval: .seconds(35, 35), kind: .sourceRecovered, reasonCode: "tap.restarted", recoverable: true),
            ],
            transcript: transcript, diarization: [], edits: [], summary: nil, scratchpad: nil,
            jobs: [job(m, .prepare, .succeeded), job(m, .transcribe, .succeeded), job(m, .diarize, .succeeded),
                   job(m, .reconcile, .succeeded), job(m, .notes, .failed, error: "notes.schemaInvalid", progress: 0.4)])
    }

    /// Pause from 30–45 s: both sources get a new epoch on resume and the timeline is not collapsed.
    public static var pausedMeeting: FixtureMeeting {
        let m = MeetingID("fx-paused")
        let duration = SessionTime.seconds(70)
        let eps = epochs(m, starts: [(.zero, .sessionStart), (.seconds(45), .resume)])
        let pause = SessionInterval.seconds(30, 45)
        return FixtureMeeting(
            name: "Paused meeting",
            meeting: Meeting(id: m, title: "Standup with a pause", createdAt: referenceDate,
                             clock: SessionClock(utcOrigin: referenceDate, timeZoneIdentifier: "Europe/London", hostTimeOriginNanos: 1_000_000_000),
                             captureState: .captured, duration: duration - .zero),
            epochs: eps,
            audioSegments: audioSegments(m, epochs: eps, covered: [.microphone: [.seconds(0, 30), .seconds(45, 70)],
                                                                    .systemOutput: [.seconds(0, 30), .seconds(45, 70)]]),
            events: [
                CaptureEvent(id: CaptureEventID("fx-p-ev1"), meetingID: m, source: nil, interval: pause, kind: .pause,
                             reasonCode: "user.pause", recoverable: true),
                CaptureEvent(id: CaptureEventID("fx-p-ev2"), meetingID: m, source: nil, interval: .seconds(45, 45),
                             kind: .resume, reasonCode: "user.resume", recoverable: true),
            ],
            transcript: nil, diarization: [], edits: [], summary: nil, scratchpad: nil,
            jobs: [job(m, .prepare, .succeeded),
                   job(m, .transcribe, .suspended, progress: 0.3, suspension: .recordingActive)])
    }

    /// Notes were generated against revision r1, then the user renamed and reassigned a speaker:
    /// the summary is stale until regenerated.
    public static var staleSummary: FixtureMeeting {
        var f = twoSourceConversation
        let m = MeetingID("fx-stale")
        f.name = "Stale summary"
        // Re-key the meeting so fixtures do not collide in a shared store.
        f.meeting.id = m
        f.meeting.title = "Launch checklist (edited)"
        f.epochs = f.epochs.map { var e = $0; e.meetingID = m; e.id = EpochID("fx-stale-" + $0.id.rawValue); return e }
        f.audioSegments = f.audioSegments.map { var s = $0; s.meetingID = m; s.id = AudioSegmentID("fx-stale-" + $0.id.rawValue)
            s.epochID = EpochID("fx-stale-" + $0.epochID.rawValue); return s }
        f.transcript?.meetingID = m
        f.diarization = f.diarization.map { var d = $0; d.meetingID = m; return d }
        f.scratchpad?.meetingID = m
        f.jobs = f.jobs.map { var j = $0; j.key.meetingID = m; j.id = JobID("fx-stale-" + $0.id.rawValue); return j }
        let rev = f.transcript!.id
        let g5 = f.transcript!.segments[5]
        f.edits = [
            UserEdit(id: EditID("fx-stale-e1"), meetingID: m, baseRevisionID: rev, sequence: 1,
                     createdAt: referenceDate.addingTimeInterval(60), operation: .renameSpeaker(SpeakerID("spk-2"), displayName: "Dana")),
            UserEdit(id: EditID("fx-stale-e2"), meetingID: m, baseRevisionID: rev, sequence: 2,
                     createdAt: referenceDate.addingTimeInterval(90),
                     operation: .reassign(WordRange(revisionID: rev, first: g5.words.first!.id, last: g5.words.last!.id),
                                          to: .new(SpeakerID("spk-4"), label: "Speaker 4"))),
        ]
        f.summary?.meetingID = m
        f.summary?.isStale = true
        return f
    }
}
