import CryptoKit
public import Foundation
public import Domain
public import Storage

/// Crash recovery for one meeting directory (plan §6 "Crash recovery").
///
/// Sources of truth, in order: database rows, journal lines, self-describing segment files. Recovery
/// - indexes committed files that lack rows (verifying each file decodes completely and hashing it);
/// - quarantines truncated/corrupt committed files and reports their intervals as damaged;
/// - salvages interrupted staging writes when format and frame boundaries can be proven (whole frames only), and
///   reports the missing remainder as a gap; otherwise quarantines them;
/// - replays journaled epochs and events missing from the database;
/// - marks an unfinished meeting `interrupted` and records its duration.
/// Original audio is never modified in place; nothing outside the meeting directory is touched.
public enum SegmentRecovery {
    public struct Result: Sendable {
        public var report: RecoveryReport
        public var salvaged: [AudioSegmentRecord]
        public var replayedEpochs: Int
        public var replayedEvents: Int
        public var segmentsIndexedTotal: Int
    }

    public static func recover(meetingID: MeetingID, directory: URL, store: MeetingStore?) throws -> Result {
        let fm = FileManager.default
        var report = RecoveryReport(meetingID: meetingID)
        var salvaged: [AudioSegmentRecord] = []
        var newEvents: [CaptureEvent] = []

        // 1. Journal (tolerates a torn last line).
        var journalSegments: [String: AudioSegmentRecord] = [:]
        var journalEpochs: [CaptureEpoch] = []
        var journalEvents: [CaptureEvent] = []
        if let text = try? String(contentsOf: directory.appending(path: "journal.jsonl"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let entry = try? ContractCoding.decode(JournalEntry.self, from: Data(line.utf8)) else { continue }
                switch entry {
                case .segment(let s): journalSegments[s.relativePath] = s
                case .epoch(let e): journalEpochs.append(e)
                case .event(let e): journalEvents.append(e)
                }
            }
        }

        // A directory without a meeting row (crash before the row was written) still gets indexed.
        if let store, try store.meeting(meetingID) == nil {
            try store.upsertMeeting(Meeting(id: meetingID, title: "Recovered recording", createdAt: Date(), captureState: .interrupted))
        }

        // 2. What the index already has.
        let indexed = Set(try store?.segments(meetingID).map(\.relativePath) ?? [])
        var toIndex: [AudioSegmentRecord] = []
        let quarantine = directory.appending(path: "audio/.quarantine")

        func quarantineFile(_ url: URL, interval: SessionInterval?) {
            try? fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let dest = quarantine.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
            try? fm.moveItem(at: url, to: dest)
            report.quarantined.append(dest.path.replacingOccurrences(of: directory.path + "/", with: ""))
            if let interval { report.damagedIntervals.append(interval) }
        }

        // 3. Committed tree: audio/<source>/<minute>/<seq>.caf
        let audio = directory.appending(path: "audio")
        let committedFiles = (fm.enumerator(at: audio, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "caf" && !$0.path.contains("/.staging/") && !$0.path.contains("/.quarantine/") }
        for url in committedFiles.sorted(by: { $0.path < $1.path }) {
            let rel = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            if indexed.contains(rel) { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            let meta = CAFFile.metadata(of: data) ?? journalSegments[rel]
            do {
                let decoded = try CAFFile.decode(data)
                guard var record = meta, Int64(decoded.frameCount) == record.frameCount, decoded.format == record.format else {
                    quarantineFile(url, interval: meta?.interval)
                    continue
                }
                record.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                record.state = .committed
                record.relativePath = rel
                toIndex.append(record)
                report.reindexed.append(record.id)
            } catch {
                quarantineFile(url, interval: meta?.interval)
            }
        }

        // 4. Interrupted staging writes.
        let staging = audio.appending(path: ".staging")
        for url in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasSuffix(".partial") {
            guard let data = try? Data(contentsOf: url), let meta = CAFFile.metadata(of: data),
                  let decoded = try? CAFFile.decode(data, salvage: true), decoded.format == meta.format else {
                quarantineFile(url, interval: nil)
                continue
            }
            let final = directory.appending(path: meta.relativePath)
            if fm.fileExists(atPath: final.path) { try? fm.removeItem(at: url); continue } // rename had completed
            guard decoded.frameCount > 0 else {
                quarantineFile(url, interval: meta.interval)
                continue
            }
            // Whole frames are proven by the header (format) and the segment's start frame; rebuild a smaller segment.
            var rec = meta
            rec.frameCount = Int64(decoded.frameCount)
            let end = rec.interval.start.advanced(byFrames: rec.frameCount, sampleRate: rec.format.sampleRate)
            if end < meta.interval.end {
                let lost = SessionInterval(unchecked: end, meta.interval.end)
                report.damagedIntervals.append(lost)
                newEvents.append(CaptureEvent(meetingID: meetingID, source: meta.source, interval: lost, kind: .gap,
                                              reasonCode: "recovery.truncatedSegment", recoverable: false,
                                              lostFrames: meta.frameCount - rec.frameCount))
            }
            rec.interval = SessionInterval(unchecked: rec.interval.start, end)
            rec.state = .committed
            let body = try ContractCoding.encode(rec)
            let bytes = decoded.samples.withUnsafeBufferPointer { CAFFile.encode(samples: $0, format: rec.format, metadata: body) }
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = staging.appending(path: "\(UUID().uuidString).salvage")
            try bytes.write(to: tmp, options: .atomic)
            guard rename(tmp.path, final.path) == 0 else { throw SegmentStoreError.io("salvage rename errno \(errno)") }
            try? fm.removeItem(at: url)
            rec.sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            salvaged.append(rec)
            toIndex.append(rec)
            report.reindexed.append(rec.id)
        }

        // 5. Replay journaled epochs/events, add recovery events, index segments, finalize meeting row.
        var replayedEpochs = 0, replayedEvents = 0
        if let store {
            let knownEpochs = Set(try store.epochs(meetingID).map(\.id))
            let missingEpochs = journalEpochs.filter { !knownEpochs.contains($0.id) }
            try store.insertEpochs(missingEpochs)
            replayedEpochs = missingEpochs.count
            let knownEvents = Set(try store.events(meetingID).map(\.id))
            let missingEvents = journalEvents.filter { !knownEvents.contains($0.id) }
            for d in report.damagedIntervals where !newEvents.contains(where: { $0.interval == d }) {
                newEvents.append(CaptureEvent(meetingID: meetingID, source: nil, interval: d, kind: .gap,
                                              reasonCode: "recovery.quarantined", recoverable: false))
            }
            try store.insertEvents(missingEvents + newEvents)
            replayedEvents = missingEvents.count
            try store.insertSegments(toIndex)
            if var m = try store.meeting(meetingID) {
                let all = try store.segments(meetingID)
                if let last = all.map(\.interval.end).max() { m.duration = SessionDuration(nanoseconds: max(m.duration.nanoseconds, last.nanoseconds)) }
                if m.captureState.isActive {
                    // Crash/kill mid-recording: the audio that was committed is kept; the session is shown as interrupted.
                    m.captureState = .interrupted
                    newEvents.append(CaptureEvent(meetingID: meetingID, source: nil,
                                                  interval: SessionInterval(unchecked: SessionTime(nanoseconds: m.duration.nanoseconds),
                                                                            SessionTime(nanoseconds: m.duration.nanoseconds)),
                                                  kind: .sourceFault, reasonCode: "recovery.appTerminated", recoverable: false))
                    try store.insertEvents([newEvents.last!])
                }
                try store.upsertMeeting(m)
            }
        }
        let total = try store?.segments(meetingID).count ?? toIndex.count
        return Result(report: report, salvaged: salvaged, replayedEpochs: replayedEpochs, replayedEvents: replayedEvents,
                      segmentsIndexedTotal: total)
    }

    /// Recovers every meeting under `store.root/meetings` that is unfinished or has unindexed files (call at launch).
    public static func recoverAll(store: MeetingStore) -> [MeetingID: Result] {
        let dir = store.root.appending(path: "meetings")
        var out: [MeetingID: Result] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let id = MeetingID(url.lastPathComponent)
            if (try? store.meeting(id)) == nil {
                // Directory without a meeting row (crash before the row was written): create a minimal row.
                try? store.upsertMeeting(Meeting(id: id, title: "Recovered recording", createdAt: Date(), captureState: .interrupted))
            }
            if let r = try? recover(meetingID: id, directory: url, store: store) { out[id] = r }
        }
        return out
    }
}
