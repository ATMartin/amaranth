import Foundation
import Domain
import Storage
import MeetingAccess

/// amaranth-access: the external read model from the command line, on an isolated library (spec 0009 evidence).
///   amaranth-access seed-demo <library-root>          one synthetic meeting with edits, stale notes and a user line
///   amaranth-access snapshot <library-root> <meeting> the meeting's external snapshot (JSON)
///   amaranth-access resolve <library-root> <url>      what a source link resolves to now
///   amaranth-access export <library-root> <destination> [--notes]  bulk snapshot export of every meeting (T99)
///   amaranth-access record-under-load <library-root> <seconds> <export-dest> [--no-load] [--ctx-load]   T100/T116 capture health
///   amaranth-access seed-eval <library-root>          the labeled T98 retrieval library (+ eval-map.json)
///   amaranth-access eval <library-root> <questions.json> <out-dir>
///   amaranth-access seed-scale <library-root> <meetings> <lines>
///   amaranth-access scale <library-root> <ops> <label> one JSON line of timings (ms) and peak memory
/// Never point it at the real library while the app runs: the app owns the library.
let args = CommandLine.arguments

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }

switch args.dropFirst().first {
case "seed-demo" where args.count >= 3:
    let store = try MeetingStore(root: URL(filePath: args[2], directoryHint: .isDirectory))
    print(try DemoLibrary.seed(store).rawValue)
case "snapshot" where args.count >= 4:
    let reader = MeetingReader(store: try MeetingStore(root: URL(filePath: args[2], directoryHint: .isDirectory)))
    guard let s = try reader.snapshot(MeetingID(args[3])) else { fail("unavailable") }
    print(String(decoding: try ExternalCoding.encoder().encode(s), as: UTF8.self))
case "resolve" where args.count >= 4:
    let reader = MeetingReader(store: try MeetingStore(root: URL(filePath: args[2], directoryHint: .isDirectory)))
    print(reader.resolve(args[3]))
case "profile" where args.count >= 3:
    let store = try MeetingStore(root: URL(filePath: args[2], directoryHint: .isDirectory))
    let id = try store.liveMeetingIDs()[0]
    var t = Date(); func lap(_ s: String) { print(s, String(format: "%.1f ms", Date().timeIntervalSince(t) * 1000)); t = Date() }
    let lib = try store.libraryID(); lap("libraryID")
    let rec = try store.readMeetingSource(id)!; lap("read")
    let d = rec.transcript!.applyingTextEdits(rec.edits); lap("applyEdits \(d.segments.count)")
    var snap = SnapshotBuilder.build(rec, libraryID: lib, readAt: Date()); lap("build (incl fingerprint)")
    _ = SnapshotBuilder.fingerprint(snap); lap("fingerprint alone")
    snap.fingerprint = ""; _ = try ExternalCoding.encoder(pretty: false).encode(snap); lap("encode")
case "export" where args.count >= 4:
    let reader = MeetingReader(store: try MeetingStore(root: URL(filePath: args[2], directoryHint: .isDirectory)))
    let ids = try BulkExport.preview(reader, scope: .all).meetingIDs
    let r = BulkExport.run(reader, meetings: ids, content: args.contains("--notes") ? .notes : .notesAndTranscript,
                           destination: URL(filePath: args[3], directoryHint: .isDirectory))
    print("status=\(r.status.rawValue) written=\(r.written) unchanged=\(r.unchanged) kept=\(r.kept.count) errors=\(r.errors.count) incomplete=\(BulkExport.isIncomplete(URL(filePath: args[3])))")
    for e in r.errors.prefix(5) { print("error: \(e.meetingID ?? "-") \(e.message)") }
    exit(r.status == .complete ? 0 : 1)
case "record-under-load" where args.count >= 5:
    try await RecordUnderLoad.run(root: URL(filePath: args[2], directoryHint: .isDirectory), seconds: Double(args[3])!,
                                  exportDest: URL(filePath: args[4], directoryHint: .isDirectory), load: !args.contains("--no-load"),
                                  ctxLoad: args.contains("--ctx-load"))
case "seed-hostile" where args.count >= 3:
    // Metadata and text built to break YAML, Markdown, HTML and paths (T99/T100 inertness checks).
    let store = try MeetingStore(root: URL(filePath: args[2], directoryHint: .isDirectory))
    let hostile = ["Q4: \"plan\"\n---\ntitle: pwned", "&anchor *alias !!python/object:os.system ['rm -rf /']", "<script>alert(1)</script>",
                   "[click](javascript:alert(1)) ![x](file:///etc/passwd)", "../../../etc/passwd", "\u{2028}line\u{2029}sep\u{85}nel\u{FEFF}bom",
                   "\u{202E}gnp.exe", "# heading\n## another", "- [ ] task | table | `code` ~~strike~~", "日本語の会議 — café ñ 🚀", "key: value\n  nested: true",
                   "see https://evil.example/x or www.evil.test, mail me@evil.example %%hidden%% ==hl== $$x$$ ^blockid"]
    let folder = try store.createFolder(name: "Clients: \"A\" & <B>").id
    for (i, t) in hostile.enumerated() {
        try Synthetic.meeting(store, key: "h\(i)", title: t, start: Date(timeIntervalSince1970: 1_788_220_800 + Double(i) * 3600), lines: hostile.map { $0.replacingOccurrences(of: "\n", with: " ") },
                              people: [t, "Ana: \"the\" boss"], folder: i % 2 == 0 ? folder : nil, notes: hostile)
    }
case "seed-eval" where args.count >= 3:
    let root = URL(filePath: args[2], directoryHint: .isDirectory)
    try EvalLibrary.seed(try MeetingStore(root: root), root: root)
case "eval" where args.count >= 5:
    try AccessEvalRun.run(root: URL(filePath: args[2], directoryHint: .isDirectory), questions: URL(filePath: args[3]), out: URL(filePath: args[4], directoryHint: .isDirectory))
case "seed-scale" where args.count >= 5:
    try Scale.seed(root: URL(filePath: args[2], directoryHint: .isDirectory), meetings: Int(args[3])!, lines: Int(args[4])!)
case "scale" where args.count >= 5:
    try Scale.run(root: URL(filePath: args[2], directoryHint: .isDirectory), ops: Int(args[3])!, label: args[4])
default:
    fail("usage: amaranth-access seed-demo|snapshot|resolve <library-root> …")
}

/// A synthetic meeting like the T97 test fixture: renamed speaker, correction, deleted line, trims, overlap, a failed
/// stretch, notes generated before the edits (stale), a rewritten generated line and a typed line.
enum DemoLibrary {
    static func seed(_ store: MeetingStore) throws -> MeetingID {
        let m = MeetingID()
        let start = Date()
        try store.upsertMeeting(Meeting(id: m, title: "Synthetic: Kestrel launch review", createdAt: start,
                                        clock: SessionClock(utcOrigin: start, timeZoneIdentifier: TimeZone.current.identifier, hostTimeOriginNanos: 0),
                                        captureState: .captured, duration: .seconds(120)))
        try store.setPeople([Person(name: "Ana"), Person(name: "Ben")], for: m)
        let s1 = SpeakerID("spk1"), s2 = SpeakerID("spk2")
        func seg(_ id: String, _ texts: [String], at t: Double, _ src: SourceKind = .systemOutput, _ who: SpeakerAssignment) -> TranscriptSegment {
            let w = texts.enumerated().map { i, x in Word(id: WordID("\(id)-w\(i)"), text: x, interval: .seconds(t + Double(i) * 0.3, t + Double(i) * 0.3 + 0.25), source: src, speaker: who) }
            return TranscriptSegment(id: TranscriptSegmentID(id), source: src, interval: SessionInterval(unchecked: w.first!.interval.start, w.last!.interval.end), words: w, speaker: who)
        }
        let segs = [seg("s0", ["early", "chatter", "removed", "by", "trim"], at: 1, .systemOutput, .speaker(s1)),
                    seg("s1", ["we", "ship", "the", "kestrl", "build", "on", "thursday"], at: 10, .systemOutput, .speaker(s1)),
                    seg("s2", ["this", "line", "gets", "deleted"], at: 20, .systemOutput, .speaker(s2)),
                    seg("s3", ["budget", "review", "is", "next", "week"], at: 30, .systemOutput, .speaker(s2)),
                    seg("s4", ["yes", "agreed"], at: 40, .microphone, .multiple([s1, s2]))]
        let t = TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: start, producer: ProducerInfo(component: "synthetic", configHash: "x"),
                                   segments: segs, coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, 50), status: .transcribed),
                                                              CoverageRegion(source: .systemOutput, interval: .seconds(50, 80), status: .failed)],
                                   speakers: [Speaker(id: s1, label: "Speaker 1"), Speaker(id: s2, label: "Speaker 2")])
        try store.publishTranscript(t)
        func ev(_ s: TranscriptSegment) -> EvidenceRef { .transcript(TranscriptEvidence(revisionID: t.id, segmentID: s.id, firstWord: s.words.first!.id, lastWord: s.words.last!.id)) }
        try store.publishSummary(SummaryRevision(meetingID: m, transcriptRevisionID: t.id, editSequence: 0, createdAt: start, producer: ProducerInfo(component: "synthetic", configHash: "x"),
                                                 promptVersion: "synthetic", content: SummaryContent(
                                                    decisions: [SummaryItem(kind: .decision, text: "Ship the kestrel build on Thursday", evidence: [ev(segs[1])])],
                                                    actionItems: [SummaryItem(kind: .actionItem, text: "Follow up on the deleted line", evidence: [ev(segs[2])], uncertain: true)]),
                                                 validation: SummaryValidationReport(status: .valid)))
        if var doc = try store.currentNotesDocument(m) {
            doc.id = RevisionID(); doc.origin = .edited
            doc.blocks += NotesComposer.userBlocks(fromText: "Book the venue", typedAt: 12)
            try store.saveNotesDocument(doc)
        }
        var n = 0
        func edit(_ op: EditOperation) throws { n += 1; try store.appendEdit(UserEdit(meetingID: m, baseRevisionID: t.id, sequence: n, createdAt: Date(), operation: op)) }
        try edit(.renameSpeaker(s1, displayName: "Dana"))
        try edit(.correctText(WordRange(revisionID: t.id, first: WordID("s1-w3"), last: WordID("s1-w3")), replacement: "kestrel"))
        try edit(.deleteText(WordRange(revisionID: t.id, first: WordID("s2-w0"), last: WordID("s2-w3"))))
        try edit(.trimTranscript(start: .seconds(5), end: nil))
        return m
    }
}
