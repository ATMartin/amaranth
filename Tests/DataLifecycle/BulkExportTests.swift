import Foundation
import Testing
@testable import Storage
import Domain
@testable import MeetingAccess

@Suite("Bulk export (T99)")
struct BulkExportTests {
    static func dest() -> URL {
        let u = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "amr-bulk-\(UUID())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
    static func allFiles(_ root: URL) -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }.map { $0.resolvingSymlinksInPath() }
    }

    @Test func multiMeetingExportMatchesCurrentContentAndLeaksNothing() throws {
        var f = try AccessFixture()
        try f.applyUserEdits()
        let notesOnly = MeetingID()
        try f.store.upsertMeeting(Meeting(id: notesOnly, title: "Hallway chat", createdAt: Date(), captureState: .idle))
        try f.store.saveNotesDocument(NotesDocumentRevision(meetingID: notesOnly, createdAt: Date(), origin: .edited, blocks: NotesComposer.userBlocks(fromText: "- Try the new venue")))
        let processing = MeetingID()
        try f.store.upsertMeeting(Meeting(id: processing, title: "Kestrel launch", createdAt: Date(), captureState: .recording))   // same title, no content yet
        let preview = try BulkExport.preview(f.reader, scope: .all)
        #expect(preview.count == 3 && preview.withTranscript == 1 && preview.notesOnly == 1 && preview.empty == 1)
        let d = Self.dest()
        let r = BulkExport.run(f.reader, meetings: preview.meetingIDs, content: .notesAndTranscript, destination: d)
        #expect(r.status == .complete && r.written == 3 && r.errors.isEmpty)
        let root = d.appending(path: "amaranth")
        let files = Self.allFiles(root).map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }.sorted()
        #expect(files == (["README.md", "manifest.json"] + [f.meeting, notesOnly, processing].flatMap { ["\($0.rawValue)/meeting.json", "\($0.rawValue)/meeting.md"] }).sorted())
        // Parity: each meeting.json is the reader's snapshot (read times aside).
        for id in [f.meeting, notesOnly, processing] {
            var exported = try ExternalCoding.decoder().decode(MeetingSnapshot.self, from: Data(contentsOf: root.appending(path: "\(id.rawValue)/meeting.json")))
            var now = try #require(try f.reader.snapshot(id))
            exported.readAt = now.readAt
            #expect(exported == now)
            now.readAt = Date(timeIntervalSince1970: 0)
        }
        let md = Self.read(root.appending(path: "\(f.meeting.rawValue)/meeting.md"))
        #expect(md.contains("we ship the kestrel build thursday") && md.contains("**Dana**") && md.contains("Call the venue _(your note)_"))
        #expect(md.contains("source removed") && md.contains("may still mention removed discussion") && md.contains("notes_stale: true"))
        #expect(md.contains("no transcript, speech could not be transcribed"))
        #expect(Self.read(root.appending(path: "\(notesOnly.rawValue)/meeting.md")).contains("Try the new venue"))
        #expect(Self.read(root.appending(path: "\(processing.rawValue)/meeting.md")).contains("transcript: \"processing\""))
        // Nothing hidden, no audio, no local paths, in any file.
        for file in Self.allFiles(root) {
            let text = Self.read(file)
            for marker in AccessFixture.hidden { #expect(!text.contains(marker), "\(marker) in \(file.lastPathComponent)") }
            #expect(!text.contains(f.root.path) && !["caf", "wav", "m4a"].contains(file.pathExtension))
        }
        // Manifest: every file with its hash; the run is committed (no marker, journal or staging left).
        let manifest = try ExternalCoding.decoder().decode(BulkExport.Manifest.self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        #expect(manifest.status == "complete" && manifest.meetings.count == 3)
        for e in manifest.meetings { for file in e.files { #expect(BulkExport.sha256(try Data(contentsOf: root.appending(path: file.path))) == file.sha256) } }
        #expect(!BulkExport.isIncomplete(d) && !FileManager.default.fileExists(atPath: root.appending(path: ".export-journal.jsonl").path))
        // Exporting again with nothing changed writes nothing.
        let again = BulkExport.run(f.reader, meetings: preview.meetingIDs, content: .notesAndTranscript, destination: d)
        #expect(again.status == .complete && again.written == 0 && again.unchanged == 3)
    }

    @Test func renamesKeepTheirUUIDPathAndNotesOnlyLevelLeavesTheTranscriptOut() throws {
        let f = try AccessFixture()
        let d = Self.dest()
        _ = BulkExport.run(f.reader, meetings: [f.meeting], content: .notesAndTranscript, destination: d)
        var m = try #require(try f.store.meeting(f.meeting)); m.title = "Renamed launch"; try f.store.upsertMeeting(m)
        let r = BulkExport.run(f.reader, meetings: [f.meeting], content: .notes, destination: d)
        #expect(r.status == .complete && r.written == 1)
        let root = d.appending(path: "amaranth")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted() == ["README.md", f.meeting.rawValue, "manifest.json"].sorted())
        let md = Self.read(root.appending(path: "\(f.meeting.rawValue)/meeting.md"))
        #expect(md.contains("# Renamed launch") && !md.contains("## Transcript") && md.contains("transcript_included: false"))
        let json = try ExternalCoding.decoder().decode(MeetingSnapshot.self, from: Data(contentsOf: root.appending(path: "\(f.meeting.rawValue)/meeting.json")))
        #expect(json.transcript.isEmpty && json.limitations.contains { $0.contains("not included in this export") })
    }

    @Test func hostileMetadataStaysInertYAMLAndMarkdown() throws {
        let lib = try RetrievalLibrary()
        let title = "Q4: \"plan\"\n---\ntitle: pwned &a !!python/object <script>alert(1)</script> [x](javascript:alert(1)) ../../etc \u{2028}x \u{202E}rtl # head"
        let m = try lib.meeting(title, lines: ["# not a heading [link](javascript:x) <img src=x> | table | ---", "1. not a list"], people: ["Ana: \"the\" boss", "- dash"],
                                folder: try lib.store.createFolder(name: "Clients: \"A\"\n").id, notes: ["## user heading?", "<b>bold</b> ![img](file:///etc/passwd)"])
        let d = Self.dest()
        #expect(BulkExport.run(lib.reader, meetings: [m], content: .notesAndTranscript, destination: d).status == .complete)
        let md = Self.read(d.appending(path: "amaranth/\(m.rawValue)/meeting.md"))
        // Front matter: exactly the expected keys, one per line; every quoted value is a valid JSON (so YAML) string.
        let lines = md.components(separatedBy: "\n")
        let end = try #require(lines.dropFirst().firstIndex(of: "---"))
        let front = lines[1..<end]
        #expect(front.count == 21)
        for l in front {
            let parts = l.split(separator: ":", maxSplits: 1).map(String.init)
            #expect(parts.count == 2 && parts[0].allSatisfy { $0.isLetter || $0 == "_" }, "bad key line: \(l)")
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") { #expect((try? JSONDecoder().decode(String.self, from: Data(v.utf8))) != nil, "bad value: \(v)") }
            if v.hasPrefix("[") { #expect((try? JSONDecoder().decode([String].self, from: Data(v.utf8))) != nil, "bad list: \(v)") }
            #expect(!v.contains("\u{2028}"))
        }
        let titleValue = try #require(front.first { $0.hasPrefix("title: ") }).dropFirst(7)
        #expect(try JSONDecoder().decode(String.self, from: Data(titleValue.utf8)) == title)
        // Body: no live HTML, no links other than Amaranth's, no injected headings or front matter.
        let body = lines[(end + 1)...].joined(separator: "\n")
        #expect(!body.contains("<script") && !body.contains("<img") && !body.contains("<b>") && !body.contains("](javascript") && !body.contains("](file:"))
        let links = body.components(separatedBy: "](").dropFirst().map { String($0.prefix(12)) }
        #expect(links.allSatisfy { $0.hasPrefix("amaranth://") })
        #expect(!body.contains("\n---\n") && !body.contains("\n# not") && !body.contains("\n## user"))
        #expect(lines.filter { $0.hasPrefix("# ") }.count == 1)
        // Paths come from the UUID only.
        #expect(Self.allFiles(d).allSatisfy { $0.path.hasPrefix(d.appending(path: "amaranth").path) })
    }

    @Test func userChangedFilesAreKeptAndReported() throws {
        let f = try AccessFixture()
        let d = Self.dest()
        _ = BulkExport.run(f.reader, meetings: [f.meeting], content: .notesAndTranscript, destination: d)
        let mdURL = d.appending(path: "amaranth/\(f.meeting.rawValue)/meeting.md")
        try "my own edits".write(to: mdURL, atomically: true, encoding: .utf8)
        var m = try #require(try f.store.meeting(f.meeting)); m.title = "Changed"; try f.store.upsertMeeting(m)
        let r = BulkExport.run(f.reader, meetings: [f.meeting], content: .notesAndTranscript, destination: d)
        #expect(r.status == .partial && r.kept.count == 1 && Self.read(mdURL) == "my own edits")
        #expect(Self.read(mdURL.deletingLastPathComponent().appending(path: "meeting.json")).contains("\"title\" : \"Changed\""))
        // Kept files keep being kept on later runs.
        #expect(BulkExport.run(f.reader, meetings: [f.meeting], content: .notesAndTranscript, destination: d).kept.count == 1)
        #expect(Self.read(mdURL) == "my own edits")
    }

    @Test func cancelledRunIsDetectableAndRetriesSafely() throws {
        let lib = try RetrievalLibrary()
        let ids = try (0..<4).map { try lib.meeting("M\($0)", lines: ["line \($0)"]) }
        let d = Self.dest()
        let counter = Counter()
        let r = BulkExport.run(lib.reader, meetings: ids, content: .notesAndTranscript, destination: d, isCancelled: { counter.next() > 2 })
        #expect(r.status == .cancelled && BulkExport.isIncomplete(d))
        #expect(!FileManager.default.fileExists(atPath: d.appending(path: "amaranth/manifest.json").path))
        // Change a meeting that was already written: the retry recognizes its own file from the journal and replaces it.
        var m = try #require(try lib.store.meeting(ids[0])); m.title = "M0 renamed"; try lib.store.upsertMeeting(m)
        let retry = BulkExport.run(lib.reader, meetings: ids, content: .notesAndTranscript, destination: d)
        #expect(retry.status == .complete && retry.kept.isEmpty && !BulkExport.isIncomplete(d))
        #expect(Self.read(d.appending(path: "amaranth/\(ids[0].rawValue)/meeting.md")).contains("# M0 renamed"))
    }

    final class Counter: @unchecked Sendable { var n = 0; func next() -> Int { n += 1; return n } }

    @Test func failuresAreReportedPerMeetingOrForTheFolder() throws {
        let lib = try RetrievalLibrary()
        let a = try lib.meeting("A", lines: ["alpha"]), b = try lib.meeting("B", lines: ["bravo"])
        // A read-only destination: the whole export fails up front with a clear message.
        let ro = Self.dest()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        let denied = BulkExport.run(lib.reader, meetings: [a, b], content: .notesAndTranscript, destination: ro)
        #expect(denied.status == .failed && denied.errors.first?.message.contains("Couldn't write") == true)
        // A file where a meeting's folder should be: that meeting fails, the other is written, the manifest says partial.
        let d = Self.dest()
        _ = BulkExport.run(lib.reader, meetings: [a, b], content: .notesAndTranscript, destination: d)
        let dirA = d.appending(path: "amaranth/\(a.rawValue)")
        try FileManager.default.removeItem(at: dirA)
        try "in the way".write(to: dirA, atomically: true, encoding: .utf8)
        var m = try #require(try lib.store.meeting(b)); m.title = "B2"; try lib.store.upsertMeeting(m)
        let r = BulkExport.run(lib.reader, meetings: [a, b], content: .notesAndTranscript, destination: d)
        #expect(r.status == .partial && r.errors.map(\.meetingID) == [a.rawValue] && r.written == 1)
        let manifest = try ExternalCoding.decoder().decode(BulkExport.Manifest.self, from: Data(contentsOf: d.appending(path: "amaranth/manifest.json")))
        #expect(manifest.status == "partial" && manifest.meetings.first { $0.meetingID == a.rawValue }?.status == "error")
        // Foreign or unknown folders and links are refused.
        let other = try RetrievalLibrary()
        let foreign = BulkExport.run(other.reader, meetings: [try other.meeting("X", lines: ["x"])], content: .notes, destination: d)
        #expect(foreign.status == .failed && foreign.errors[0].message.contains("another Amaranth library"))
        let unknown = Self.dest()
        try FileManager.default.createDirectory(at: unknown.appending(path: "amaranth"), withIntermediateDirectories: true)
        try "mine".write(to: unknown.appending(path: "amaranth/notes.txt"), atomically: true, encoding: .utf8)
        #expect(BulkExport.run(lib.reader, meetings: [a], content: .notes, destination: unknown).errors[0].message.contains("didn't create"))
        let linked = Self.dest()
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "amaranth"), withDestinationURL: Self.dest())
        #expect(BulkExport.run(lib.reader, meetings: [a], content: .notes, destination: linked).errors[0].message.contains("is a link"))
    }
}

@Suite("Bulk export wording (T99)")
struct BulkExportWordingTests {
    @Test func previewAndOutcomeSayWhatHappened() {
        let p = BulkExport.Preview(meetingIDs: [MeetingID(), MeetingID(), MeetingID()], withTranscript: 2, withNotes: 2, notesOnly: 1, empty: 0)
        #expect(BulkExportWording.preview(p, content: .notesAndTranscript) == "3 meetings · 2 with transcripts · 2 with notes · 1 notes only")
        #expect(BulkExportWording.preview(p, content: .notes) == "3 meetings · 2 with notes")
        var r = BulkExport.Result(status: .partial, root: URL(filePath: "/tmp"), written: 2, unchanged: 1)
        r.kept = [.init(meetingID: "m", title: "T", message: "kept")]
        #expect(BulkExportWording.summary(r, total: 3) == "2 meetings written, 1 unchanged. 1 file was changed outside Amaranth and was kept as it is.")
        #expect(BulkExportWording.snapshotExplanation.contains("doesn't delete it there") && BulkExportWording.snapshotExplanation.contains("Audio is never included"))
    }
}
