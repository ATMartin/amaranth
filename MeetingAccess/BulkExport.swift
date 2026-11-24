public import Foundation
public import Domain
public import Storage
import Export
import CryptoKit

/// Snapshot export of selected meetings, a folder or the whole library (spec 0009 §4, T99): portable Markdown and
/// versioned JSON in a dedicated `amaranth/` folder, one `<meeting-uuid>/` folder per meeting, and a manifest written
/// last. A snapshot is a copy: later edits or deletions in Amaranth don't reach it, and Amaranth never deletes it.
///
/// Publication: each file is written to a staging folder inside `amaranth/` and renamed over its destination (atomic on
/// one volume), and recorded in a journal; `.export-in-progress.json` marks a run until its manifest is committed. A
/// destination file is replaced only when its bytes are ones Amaranth wrote (a hash in the manifest or the journal);
/// anything else is kept and reported as changed outside Amaranth. Retrying after a cancel, a crash or a full disk is
/// therefore safe.
public enum BulkExport {
    public static let folderName = "amaranth"
    public static let manifestName = "manifest.json"
    static let markerName = ".export-in-progress.json"
    static let journalName = ".export-journal.jsonl"
    static let stagingName = ".staging"

    public enum Content: String, Codable, Sendable, CaseIterable {
        case notesAndTranscript, notes
    }

    /// What an export would contain (shown before choosing a destination).
    public struct Preview: Sendable, Equatable {
        public var meetingIDs: [MeetingID]
        public var withTranscript: Int
        public var withNotes: Int
        /// Notes without a transcript (exported as notes only).
        public var notesOnly: Int
        /// Neither yet (still processing, or nothing was captured): exported as metadata with their state.
        public var empty: Int
        public var count: Int { meetingIDs.count }
    }

    public struct Result: Sendable, Equatable {
        public enum Status: String, Sendable { case complete, partial, cancelled, failed }
        public struct Issue: Sendable, Equatable { public var meetingID: String?; public var title: String?; public var message: String }
        public var status: Status
        public var root: URL
        /// Meetings whose files were written (new or updated) / already up to date.
        public var written = 0
        public var unchanged = 0
        /// Files changed outside Amaranth since it wrote them: kept as they are, not replaced.
        public var kept: [Issue] = []
        public var errors: [Issue] = []
    }

    // MARK: Manifest

    public struct Manifest: Codable, Sendable, Equatable {
        public var format = "amaranth-export-manifest"
        public var version = 1
        public var libraryID: String
        /// The run that last wrote this manifest.
        public var exportID: String
        public var startedAt: Date
        public var finishedAt: Date
        /// complete: every meeting of that run written; partial: some kept or failed (see entries).
        public var status: String
        public var content: Content
        /// Every meeting this folder holds, including ones from earlier runs (their `exportedAt` is older).
        public var meetings: [Entry]
        /// Other files Amaranth wrote here (README.md).
        public var otherFiles: [File]? = nil

        public struct Entry: Codable, Sendable, Equatable {
            public var meetingID: String
            public var title: String
            public var path: String
            public var fingerprint: String?
            public var readAt: Date?
            public var exportedAt: Date
            /// written, unchanged, kept (a file was changed outside Amaranth), error
            public var status: String
            public var error: String?
            public var files: [File]
        }
        public struct File: Codable, Sendable, Equatable { public var path: String; public var sha256: String; public var bytes: Int }
    }

    // MARK: Preview

    /// Meetings in `scope`, newest first, and what they contain.
    public static func preview(_ reader: MeetingReader, scope: AccessScope) throws -> Preview {
        let entries = MeetingReader.matching(try reader.store.meetingCatalog().entries, MeetingFilter(), scope: scope)
        var p = Preview(meetingIDs: entries.map(\.meeting.id), withTranscript: 0, withNotes: 0, notesOnly: 0, empty: 0)
        for e in entries {
            let t = e.meeting.currentTranscriptRevisionID != nil || e.meeting.provisionalTranscriptRevisionID != nil
            if t { p.withTranscript += 1 }
            if e.hasNotesDocument { p.withNotes += 1 }
            if !t && e.hasNotesDocument { p.notesOnly += 1 }
            if !t && !e.hasNotesDocument { p.empty += 1 }
        }
        return p
    }

    // MARK: Run

    /// Exports `meetings` into `destination/amaranth/`. `progress(done, total)` is called after each meeting.
    public static func run(_ reader: MeetingReader, meetings: [MeetingID], content: Content, destination: URL, now: @Sendable () -> Date = Date.init,
                           isCancelled: @Sendable () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }) -> Result {
        let fm = FileManager.default
        let root = destination.appending(path: folderName, directoryHint: .isDirectory)
        var result = Result(status: .failed, root: root)
        func fail(_ message: String) -> Result { result.errors.append(.init(meetingID: nil, title: nil, message: message)); result.status = .failed; return result }
        let libraryID: String
        do { libraryID = try reader.store.libraryID() } catch { return fail("Couldn't read the library: \(error.localizedDescription)") }

        // The folder must be ours (or new): never write into someone else's directory or follow a link out of it.
        if isSymlink(root) { return fail("“\(folderName)” in that folder is a link. Choose a folder where Amaranth can create its own “\(folderName)” folder.") }
        var previous: Manifest?
        // A journal with neither a marker nor a manifest can't be attributed to a library (the marker was removed by hand).
        if fm.fileExists(atPath: root.appending(path: journalName).path), !fm.fileExists(atPath: root.appending(path: markerName).path),
           !fm.fileExists(atPath: root.appending(path: manifestName).path) {
            return fail("The “\(folderName)” folder there holds an unfinished export Amaranth can't identify. Choose another folder.")
        }
        // An unfinished run (no manifest yet) is only ours to continue if its marker names this library.
        if let data = try? Data(contentsOf: root.appending(path: markerName)) {
            guard let marker = try? JSONDecoder().decode([String: String].self, from: data), marker["libraryID"] == libraryID else {
                return fail("The “\(folderName)” folder there holds an unfinished export from another Amaranth library. Choose another folder.")
            }
        }
        if fm.fileExists(atPath: root.path) {
            if let data = try? Data(contentsOf: root.appending(path: manifestName)) {
                guard let m = try? ExternalCoding.decoder().decode(Manifest.self, from: data), m.format == "amaranth-export-manifest" else {
                    return fail("The “\(folderName)” folder there has a manifest Amaranth can't read. Choose another folder.")
                }
                guard m.libraryID == libraryID else { return fail("The “\(folderName)” folder there was exported from another Amaranth library. Choose another folder.") }
                previous = m
            } else if !fm.fileExists(atPath: root.appending(path: journalName).path),
                      let items = try? fm.contentsOfDirectory(atPath: root.path), !items.filter({ !$0.hasPrefix(".") }).isEmpty {
                return fail("That folder already has a “\(folderName)” folder that Amaranth didn't create. Choose another folder.")
            }
        }
        let exportID = UUID().uuidString.lowercased()
        let started = now()
        let staging = root.appending(path: "\(stagingName)/\(exportID)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let marker = try ExternalCoding.encoder().encode(["exportID": exportID, "libraryID": libraryID, "startedAt": ExternalCoding.iso.string(from: started)])
            try marker.write(to: root.appending(path: markerName), options: .atomic)
        } catch {
            return fail("Couldn't write to that folder: \(error.localizedDescription)")
        }
        // Hashes of files Amaranth wrote here: the last manifest plus every run's journal (an unfinished run's files).
        var known = Set((previous?.meetings.flatMap { $0.files.map(\.sha256) } ?? []) + (previous?.otherFiles ?? []).map(\.sha256))
        let journalURL = root.appending(path: journalName)
        if let j = try? String(contentsOf: journalURL, encoding: .utf8) {
            for line in j.split(separator: "\n") {
                if let d = try? JSONDecoder().decode([String: String].self, from: Data(line.utf8)), let h = d["sha256"] { known.insert(h) }
            }
        }
        if !fm.fileExists(atPath: journalURL.path) { fm.createFile(atPath: journalURL.path, contents: nil) }
        let journal = try? FileHandle(forWritingTo: journalURL)
        _ = try? journal?.seekToEnd()
        defer { try? journal?.close(); try? fm.removeItem(at: staging) }

        /// Publishes one file. Returns its manifest record, or nil when an existing file was kept.
        func publish(_ data: Data, at relative: String) throws -> (Manifest.File, written: Bool)? {
            let dest = root.appending(path: relative)
            let hash = sha256(data)
            let record = Manifest.File(path: relative, sha256: hash, bytes: data.count)
            if isSymlink(dest) || isSymlink(dest.deletingLastPathComponent()) { throw ExportError.link(relative) }
            if let existing = try? Data(contentsOf: dest) {
                let h = sha256(existing)
                if h == hash { return (record, false) }
                guard known.contains(h) else { return nil }   // changed outside Amaranth: keep it
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = staging.appending(path: UUID().uuidString)
            do {
                try data.write(to: temp)
                let h = try FileHandle(forUpdating: temp)   // on disk before the rename, so a power loss can't leave an empty file
                try h.synchronize(); try h.close()
            } catch {
                try? fm.removeItem(at: temp)
                throw ExportError.write(relative, (error as NSError).localizedFailureReason ?? (error as NSError).underlyingErrors.first?.localizedDescription ?? error.localizedDescription)
            }
            guard rename(temp.path, dest.path) == 0 else { throw ExportError.posix(errno, relative) }
            known.insert(hash)
            try? journal?.write(contentsOf: Data((String(decoding: try JSONEncoder().encode(["path": relative, "sha256": hash]), as: UTF8.self) + "\n").utf8))
            return (record, true)
        }

        var entries: [String: Manifest.Entry] = Dictionary((previous?.meetings ?? []).map { ($0.meetingID, $0) }, uniquingKeysWith: { a, _ in a })
        var cancelled = false
        var otherFiles = previous?.otherFiles ?? []
        do {
            if let (record, _) = try publish(Data(readme.utf8), at: "README.md") { otherFiles = [record] }
        } catch {
            result.errors.append(.init(meetingID: nil, title: nil, message: "README.md: \(error.localizedDescription)"))
        }
        for (i, id) in meetings.enumerated() {
            if isCancelled() { cancelled = true; break }
            defer { progress(i + 1, meetings.count) }
            guard let uuid = UUID(uuidString: id.rawValue) else {
                result.errors.append(.init(meetingID: id.rawValue, title: nil, message: "Not a meeting ID that can name a folder."))
                continue
            }
            let dir = uuid.uuidString.lowercased()
            var entry = Manifest.Entry(meetingID: id.rawValue, title: "", path: dir, fingerprint: nil, readAt: nil, exportedAt: now(), status: "written", error: nil, files: [])
            do {
                guard let snap = try reader.snapshot(id, now: now()) else {
                    result.errors.append(.init(meetingID: id.rawValue, title: nil, message: "The meeting was deleted before it could be exported."))
                    continue
                }
                entry.title = snap.title; entry.fingerprint = snap.fingerprint; entry.readAt = snap.readAt
                // Same content as last time and the files still as Amaranth wrote them: leave them (and their read time).
                if let old = entries[id.rawValue], old.fingerprint == snap.fingerprint, previous?.content == content, old.status != "error",
                   old.files.count == 2, old.files.allSatisfy({ (try? Data(contentsOf: root.appending(path: $0.path))).map(sha256) == $0.sha256 }) {
                    entry = old; entry.status = "unchanged"
                    entries[id.rawValue] = entry
                    result.unchanged += 1
                    continue
                }
                let files = [("meeting.md", Data(MeetingFiles.markdown(snap, content: content).utf8)),
                             ("meeting.json", try MeetingFiles.json(snap, content: content))]
                var anyWritten = false, anyKept = false
                for (name, data) in files {
                    if let (record, written) = try publish(data, at: "\(dir)/\(name)") {
                        entry.files.append(record); anyWritten = anyWritten || written
                    } else {
                        anyKept = true
                        // Keep the hash Amaranth last wrote, so a later run still recognizes its own other files.
                        if let old = entries[id.rawValue]?.files.first(where: { $0.path == "\(dir)/\(name)" }) { entry.files.append(old) }
                        result.kept.append(.init(meetingID: id.rawValue, title: snap.title, message: "\(dir)/\(name) was changed outside Amaranth and was kept."))
                    }
                }
                entry.status = anyKept ? "kept" : anyWritten ? "written" : "unchanged"
                if anyWritten { result.written += 1 } else if !anyKept { result.unchanged += 1 }
            } catch {
                entry.status = "error"; entry.error = error.localizedDescription
                // Files written before the error keep their new hashes; the others keep what Amaranth wrote last.
                let written = Set(entry.files.map(\.path))
                entry.files += (entries[id.rawValue]?.files ?? []).filter { !written.contains($0.path) }
                result.errors.append(.init(meetingID: id.rawValue, title: entry.title.isEmpty ? nil : entry.title, message: error.localizedDescription))
            }
            entries[id.rawValue] = entry
        }
        if cancelled {
            result.status = .cancelled   // marker and journal stay: the folder reads as incomplete, and a retry is safe
            return result
        }
        // Commit: the manifest, last. Only then is the run complete.
        let manifest = Manifest(libraryID: libraryID, exportID: exportID, startedAt: started, finishedAt: now(),
                                status: result.errors.isEmpty && result.kept.isEmpty ? "complete" : "partial", content: content,
                                meetings: entries.values.sorted { $0.meetingID < $1.meetingID }, otherFiles: otherFiles)
        do {
            let temp = staging.appending(path: manifestName)
            try ExternalCoding.encoder().encode(manifest).write(to: temp)
            guard rename(temp.path, root.appending(path: manifestName).path) == 0 else { throw ExportError.posix(errno, manifestName) }
        } catch {
            result.errors.append(.init(meetingID: nil, title: nil, message: "The manifest couldn't be written, so this export is incomplete: \(error.localizedDescription)"))
            result.status = .failed
            return result
        }
        try? fm.removeItem(at: root.appending(path: markerName))
        try? fm.removeItem(at: journalURL)
        try? fm.removeItem(at: root.appending(path: stagingName))
        result.status = manifest.status == "complete" ? .complete : .partial
        return result
    }

    /// True when a previous run didn't finish (cancelled, interrupted or failed before its manifest).
    public static func isIncomplete(_ destination: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination.appending(path: "\(folderName)/\(markerName)").path)
    }

    enum ExportError: LocalizedError {
        case posix(Int32, String)
        case link(String)
        case write(String, String)
        var errorDescription: String? {
            switch self {
            case .posix(let e, let path): "\(path): \(String(cString: strerror(e)))"
            case .link(let path): "\(path) is a link; Amaranth doesn't write through links."
            case .write(let path, let why): "\(path) couldn't be written: \(why)"
            }
        }
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static let readme = """
        # Amaranth export

        Meetings exported from Amaranth, one folder per meeting (named by the meeting's ID, so renaming a meeting never
        duplicates it). Each has `meeting.md` (Markdown with YAML front matter) and `meeting.json` (`amaranth-meeting`
        version 1). `manifest.json` lists every meeting here with the hashes of the files Amaranth wrote.

        This is a snapshot: a copy made when you exported. Later edits in Amaranth don't change these files, and deleting a
        meeting in Amaranth doesn't delete it here. If this folder is synced or indexed by another app, copies may exist
        there too. Export again to update; files you changed here are kept, not overwritten.

        Notes are exported as they are shown in Amaranth. If transcript lines were deleted, the notes may still mention
        them: edit or regenerate the notes in Amaranth to remove a topic, then export again. Audio is never included.
        `amaranth://` links open the cited line in Amaranth on this Mac.

        """
}

/// The per-meeting files (T99).
public enum MeetingFiles {
    /// The snapshot JSON; with `.notes` the transcript and gaps are left out (and said so in `limitations`).
    public static func json(_ s: MeetingSnapshot, content: BulkExport.Content) throws -> Data {
        var s = s
        if content == .notes {
            s.transcript = []; s.gaps = []
            s.limitations.append("The transcript is not included in this export (notes only).")
        }
        return try ExternalCoding.encoder().encode(s) + Data("\n".utf8)
    }

    /// Markdown with YAML front matter. Every meeting-derived string in the front matter is a double-quoted scalar
    /// (JSON string escaping, which YAML accepts), and the body escapes Markdown syntax, so titles, notes and speech can
    /// never become YAML structure, links, HTML or headings. Links in the body are only Amaranth's own citation URLs.
    public static func markdown(_ s: MeetingSnapshot, content: BulkExport.Content) -> String {
        func q(_ v: String) -> String { yamlString(v) }
        func line(_ v: String) -> String { inert(v.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")) }
        var out = ["---",
                  "schema: \"amaranth-meeting-md\"",
                  "version: 1",
                  "meeting_id: \(q(s.meetingID))",
                  "library_id: \(q(s.libraryID))",
                  "title: \(q(s.title))",
                  "start: \(q(ExternalCoding.iso.string(from: s.start)))",
                  "time_zone: \(s.timeZone.map(q) ?? "null")",
                  "duration_seconds: \(s.durationNs / 1_000_000_000)",
                  "folder: \(s.folder.map { q($0.name) } ?? "null")",
                  "people: [\(s.people.map(q).joined(separator: ", "))]",
                  "transcript: \(q(s.state.transcript))",
                  "transcript_included: \(content == .notesAndTranscript)",
                  "notes: \(q(s.state.notes))",
                  "notes_stale: \(s.state.notesStale)",
                  "transcript_lines_removed: \(s.state.transcriptLinesRemoved)",
                  "audio: \(q(s.state.audio))",
                  "transcript_revision: \(s.revisions.transcript.map(q) ?? "null")",
                  "notes_revision: \(s.revisions.notes.map(q) ?? "null")",
                  "fingerprint: \(q(s.fingerprint))",
                  "read_at: \(q(ExternalCoding.iso.string(from: s.readAt)))",
                  "citation: \(q(s.citation))",
                  "---", ""]
        out.append("# \(line(s.title.isEmpty ? "Meeting" : s.title))")
        out.append("")
        var meta = [wallClock(s)]
        meta.append("Duration \(clock(s.durationNs))")
        if !s.people.isEmpty { meta.append("People: " + s.people.joined(separator: ", ")) }
        if let f = s.folder { meta.append("Folder: \(f.name)") }
        out.append("_" + line(meta.joined(separator: " · ")) + "_ · " + link("Open in Amaranth", s.citation))
        out.append("")
        var limits = s.limitations
        if content == .notes { limits.append("The transcript is not included in this export (notes only).") }
        if !limits.isEmpty { out += limits.map { "> " + line($0) } + [""] }

        out.append("## Notes")
        out.append("")
        if s.notes.isEmpty { out += ["_No notes._", ""] }
        let starts = Dictionary(s.transcript.map { ($0.citation, $0.startNs) }, uniquingKeysWith: { a, _ in a })
        for n in s.notes {
            if n.kind == "heading" { out += ["", (n.section != nil ? "### " : "#### ") + line(n.text), ""]; continue }
            var text = line(n.text)
            if let d = n.detail { text += " — " + line(d.split(separator: " ").joined(separator: " ")) }
            var extras: [String] = []
            if n.author == "user" { extras.append("your note") }
            if n.uncertain { extras.append("uncertain") }
            let cites = n.evidence.prefix(3).compactMap { e -> String? in
                switch e.status {
                case "current": e.citation.map { c in link(e.type == "userNote" ? "your note" : clock(e.startNs ?? starts[c] ?? 0), c) }
                case "removed": "source removed"
                default: "source in an earlier transcript"
                }
            }
            if !cites.isEmpty { extras.append("see " + cites.joined(separator: ", ")) }
            if !extras.isEmpty { text += " _(" + extras.joined(separator: "; ") + ")_" }
            out.append((n.kind == "bullet" ? "- " : "") + text + (n.kind == "bullet" ? "" : "\n"))
        }
        out.append("")
        guard content == .notesAndTranscript else { return out.joined(separator: "\n") + "\n" }

        out += ["## Transcript", ""]
        if s.transcript.isEmpty && s.gaps.isEmpty { out += ["_No transcript (\(s.state.transcript))._", ""] }
        var gaps = s.gaps
        for l in s.transcript {
            while let g = gaps.first, g.startNs <= l.startNs { out.append(gapLine(g)); gaps.removeFirst() }
            let flags = l.flags.filter { $0 != "corrected" }
            out.append(link(clock(l.startNs), l.citation) + " **\(line(l.speaker))** _(\(l.source == "microphone" ? "mic" : "system audio"))_: \(line(l.text))"
                       + (flags.isEmpty ? "" : " _[\(flags.joined(separator: ", "))]_") + "  ")
        }
        out += gaps.map(gapLine)
        return out.joined(separator: "\n") + "\n"
    }

    /// Meeting text for the Markdown body: the shared escaping, plus what notes apps add on top of CommonMark. `%`, `=`,
    /// `$` and `^` are escaped (Obsidian comments, highlights, math, block IDs), and a zero-width space breaks bare
    /// URLs, `www.` and e-mail addresses so GFM/Obsidian don't turn spoken text into clickable links.
    static func inert(_ v: String) -> String {
        var s = Exporter.escapeMarkdown(v)
        for ch in ["%", "=", "$", "^"] { s = s.replacingOccurrences(of: ch, with: "\\" + ch) }
        s = s.replacingOccurrences(of: "\\\\" + "=", with: "\\=")   // a leading "=" was already escaped once
        return s.replacingOccurrences(of: "://", with: ":\u{200B}//").replacingOccurrences(of: "www.", with: "www\u{200B}.", options: .caseInsensitive)
            .replacingOccurrences(of: "@", with: "\u{200B}@")
    }

    /// A link to an Amaranth citation, or the bare label when there is none (`SourceURL.string` is empty for odd IDs).
    static func link(_ label: String, _ url: String) -> String { url.hasPrefix("amaranth://") ? "[\(label)](\(url))" : label }

    static func gapLine(_ g: MeetingSnapshot.Gap) -> String {
        "_[\(clock(g.startNs))–\(clock(g.endNs))] \(g.source == "microphone" ? "mic" : "system audio"): no transcript, \(g.reason)_  "
    }

    static func clock(_ ns: Int64) -> String {
        let s = Int(ns / 1_000_000_000)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    static func wallClock(_ s: MeetingSnapshot) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        f.timeZone = s.timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")
        return f.string(from: s.start)
    }

    /// A YAML double-quoted scalar: JSON string escaping plus the line separators YAML would otherwise fold.
    static func yamlString(_ v: String) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? String(decoding: e.encode(v), as: UTF8.self)) ?? "\"\""
        return json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{85}", with: "\\u0085").replacingOccurrences(of: "\u{FEFF}", with: "\\uFEFF")
    }
}

/// What the Export Meetings sheet says (T99), kept here so it is tested with the export itself.
public enum BulkExportWording {
    public static let snapshotExplanation = "This makes a copy of the meetings as they are now, in an “amaranth” folder inside the folder you choose. Later edits in Amaranth don't update it, and deleting a meeting in Amaranth doesn't delete it there. If the folder is synced or used by a notes app, those apps may keep their own copies. Audio is never included."

    public static func preview(_ p: BulkExport.Preview, content: BulkExport.Content) -> String {
        guard p.count > 0 else { return "No meetings to export." }
        var parts = ["\(p.count) \(p.count == 1 ? "meeting" : "meetings")"]
        if content == .notesAndTranscript { parts.append("\(p.withTranscript) with \(p.withTranscript == 1 ? "a transcript" : "transcripts")") }
        parts.append("\(p.withNotes) with notes")
        if p.notesOnly > 0 && content == .notesAndTranscript { parts.append("\(p.notesOnly) notes only") }
        if p.empty > 0 { parts.append("\(p.empty) with nothing yet (exported with their status)") }
        return parts.joined(separator: " · ")
    }

    public static func title(_ r: BulkExport.Result) -> String {
        switch r.status {
        case .complete: "Export finished"
        case .partial: "Export finished with problems"
        case .cancelled: "Export stopped"
        case .failed: "Export failed"
        }
    }

    public static func summary(_ r: BulkExport.Result, total: Int) -> String {
        switch r.status {
        case .cancelled:
            return "Some meetings were written; the folder is marked unfinished. Export again to the same folder to finish it."
        case .failed:
            return r.errors.first?.message ?? "Nothing was exported."
        case .complete, .partial:
            var s = "\(r.written) \(r.written == 1 ? "meeting" : "meetings") written"
            if r.unchanged > 0 { s += ", \(r.unchanged) unchanged" }
            if !r.kept.isEmpty { s += ". \(r.kept.count) \(r.kept.count == 1 ? "file was" : "files were") changed outside Amaranth and \(r.kept.count == 1 ? "was" : "were") kept as \(r.kept.count == 1 ? "it is" : "they are")" }
            if !r.errors.isEmpty { s += ". \(r.errors.count) \(r.errors.count == 1 ? "meeting" : "meetings") couldn't be exported" }
            return s + "."
        }
    }
}
