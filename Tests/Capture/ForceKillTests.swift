import Foundation
import Testing
@testable import Capture
import Domain
import Storage

/// T05 acceptance: random force-kill (SIGKILL) of a recording process under CPU load; every committed segment is
/// recovered, no index row points at a missing file, and tail loss stays within 5 s.
@Suite("Force-kill recovery", .serialized)
struct ForceKillTests {
    static var childBinary: URL {
        // swift test puts executables next to the test bundle.
        Bundle(for: BundleLocator.self).bundleURL.deletingLastPathComponent().appending(path: "amaranth-recorder-child")
    }

    struct Outcome { var killAt: Double; var tailLoss: [SourceKind: Double]; var segments: Int; var quarantined: Int }

    func killOnce(after seconds: Double) throws -> Outcome {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-kill-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = Process()
        p.executableURL = Self.childBinary
        p.arguments = [root.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        // Wait for STARTED line.
        var line = ""
        let h = out.fileHandleForReading
        while !line.contains("\n") { line += String(decoding: h.availableData, as: UTF8.self) }
        let parts = line.split(separator: " ")
        guard parts.first == "STARTED", parts.count >= 3, let origin = UInt64(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            p.terminate(); throw CocoaError(.featureUnsupported)
        }
        let meeting = MeetingID(String(parts[1]))
        Thread.sleep(forTimeInterval: seconds)
        let killHost = HostClock.nowNanos()
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
        let killAt = Double(killHost - origin) / 1e9

        // "Relaunch": a fresh store over the same files, then recovery.
        let store = try MeetingStore(root: root)
        let results = SegmentRecovery.recoverAll(store: store)
        let r = try #require(results[meeting])
        let rows = try store.segments(meeting)
        for row in rows { #expect(FileManager.default.fileExists(atPath: store.meetingDirectory(meeting).appending(path: row.relativePath).path)) }
        // Every committed file on disk is indexed.
        let audio = store.meetingDirectory(meeting).appending(path: "audio")
        let files = (FileManager.default.enumerator(at: audio, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "caf" && !$0.path.contains("/.quarantine/") && !$0.path.contains("/.staging/") }
        #expect(files.count == rows.count, "every committed file is indexed (\(files.count) files, \(rows.count) rows)")
        #expect(try store.meeting(meeting)?.captureState == .interrupted)
        var loss: [SourceKind: Double] = [:]
        for kind in SourceKind.allCases {
            let end = rows.filter { $0.source == kind }.map(\.interval.end.seconds).max() ?? 0
            loss[kind] = killAt - end
        }
        return Outcome(killAt: killAt, tailLoss: loss, segments: rows.count, quarantined: r.report.quarantined.count)
    }

    @Test func randomKillsUnderLoadRecoverEverythingWithBoundedTailLoss() throws {
        // Reference-ish load: 4 busy threads for the duration of the test.
        let stop = Flag()
        for _ in 0..<4 { Thread.detachNewThread { var x = 0.0; while !stop.isSet { x = sin(x + 1) } } }
        defer { stop.set() }
        var worst = 0.0
        for _ in 0..<5 {
            let o = try killOnce(after: Double.random(in: 3.0...9.0))
            let w = o.tailLoss.values.max() ?? 99
            worst = max(worst, w)
            print("[force-kill] killed at \(String(format: "%.2f", o.killAt)) s: segments=\(o.segments) quarantined=\(o.quarantined) " +
                  "tail loss mic=\(String(format: "%.2f", o.tailLoss[.microphone] ?? -1)) s sys=\(String(format: "%.2f", o.tailLoss[.systemOutput] ?? -1)) s")
            #expect(w <= 5.0, "tail loss \(w) s exceeds 5 s")
            #expect(o.segments > 0)
        }
        print("[force-kill] worst tail loss over 5 kills: \(String(format: "%.2f", worst)) s")
    }
}

/// Anchors `Bundle(for:)` to the test bundle so the child executable built alongside it can be found.
final class BundleLocator {}
