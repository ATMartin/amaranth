import Foundation
import Testing
@testable import Capture
import Domain
import Storage

/// T05 acceptance: a two-hour capture does not accumulate PCM in memory, and timeline drift at known alignment markers
/// stays below 100 ms after normalization. Two-hour synthetic session at 60× (≈ 2 min); mic and system devices are
/// clocked +50 ppm and −50 ppm against the host, so their raw sample-count timelines diverge by ~0.7 s over two hours.
@Suite("Two-hour session", .serialized)
struct LongSessionTests {
    @Test(.timeLimit(.minutes(5)))
    func twoHoursFlatMemoryAndMarkersAlignedAfterNormalization() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-long-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let ppm: [SourceKind: Double] = [.microphone: 50, .systemOutput: -50]
        // Markers at host times k·600 s after each source's first frame: frame = T / (1 + ppm·1e-6) · rate.
        func markerFrames(_ p: Double) -> Set<Int64> {
            Set((1...11).map { Int64((Double($0) * 600 / (1 + p / 1e6) * 16_000).rounded()) })
        }
        // The session runs in the child recorder process: its footprint is measured there, uncontaminated by
        // other test suites running in parallel in this process.
        let p = Process()
        p.executableURL = ForceKillTests.childBinary
        p.arguments = ["--long", root.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let fields = try #require(text.split(separator: "\n").first { $0.hasPrefix("LONG ") }).split(separator: " ")
        let meeting = MeetingID(String(fields[1]))
        let growthMiB = Double(fields[2])!, maxMiB = Double(fields[3])!
        let store = try MeetingStore(root: root)
        let segments = try store.segments(meeting)
        print(String(format: "[long] segments %d, recorder-process footprint growth %.1f MiB (minute 15 → end), max %.1f MiB", segments.count, growthMiB, maxMiB))
        #expect(growthMiB < 50, "memory growth between minute 15 and the end must stay < 50 MiB")
        #expect(try store.events(meeting).filter(\.isMissingAudio).isEmpty)
        let directory = store.meetingDirectory(meeting)

        var worstNormalized = 0.0, worstRaw = 0.0
        var normalizedMarker: [SourceKind: [Double]] = [:]
        for kind in SourceKind.allCases {
            let segs = segments.filter { $0.source == kind }
            let norm = TimelineNormalizer(segments: segs)
            let firstObserved = try #require(segs.min { $0.sequence < $1.sequence }?.observedStart).seconds
            #expect(segs.map(\.interval.end.seconds).max() ?? 0 > 7000)
            for f in markerFrames(ppm[kind]!).sorted() {
                let k = Double(normalizedMarker[kind, default: []].count + 1)
                guard let seg = segs.first(where: { $0.firstFrameInEpoch <= f && $0.firstFrameInEpoch + $0.frameCount > f }) else {
                    Issue.record("\(kind) marker frame \(f) not covered"); continue
                }
                let d = try CAFFile.decode(Data(contentsOf: directory.appending(path: seg.relativePath)))
                let idx = try #require(d.samples.firstIndex { $0 > 0.5 }, "marker present in audio")
                let expected = firstObserved + k * 600
                let raw = seg.interval.start.seconds + Double(idx) / 16_000
                let normalized = norm.time(segment: seg, frame: Int64(idx)).seconds
                worstRaw = max(worstRaw, abs(raw - expected))
                worstNormalized = max(worstNormalized, abs(normalized - expected))
                normalizedMarker[kind, default: []].append(normalized - firstObserved)
            }
        }
        let crossSource = zip(normalizedMarker[.microphone] ?? [], normalizedMarker[.systemOutput] ?? []).map { abs($0 - $1) }.max() ?? 99
        print(String(format: "[long] marker error vs host time: raw sample-count timeline worst %.0f ms; normalized worst %.1f ms; mic↔system normalized worst %.1f ms",
                     worstRaw * 1000, worstNormalized * 1000, crossSource * 1000))
        #expect(worstRaw > 0.2, "the test must actually exercise drift (raw timelines diverge)")
        #expect(worstNormalized < 0.1)
        #expect(crossSource < 0.1)
    }
}
