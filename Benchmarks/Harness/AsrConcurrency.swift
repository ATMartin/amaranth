import ASR
import CoreML
import Diarization
import Domain
import Darwin
import Foundation

// T17: is there throughput to gain from running ASR instances (or ASR and diarization) concurrently, and does a
// window's decode cost depend on its length?
//
//   amaranth-bench asr-concurrency <ModelStore> <analysis.wav> [--seconds 600]
enum AsrConcurrency {
    static func now() -> ContinuousClock.Instant { .now }
    static func secs(_ t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func makeASR(_ store: URL, units: MLComputeUnits? = nil) throws -> ParakeetASR {
        try ParakeetASR(directory: store.appending(path: "parakeet-tdt-0.6b-v3-coreml"),
                        manifestID: ModelManifestID("parakeet-tdt-0.6b-v3-coreml"), revision: "local", encoderComputeUnits: units)
    }

    static func decode(_ asr: ParakeetASR, _ windows: [[Float]]) async throws -> [[ParakeetASR.Word]] {
        var out: [[ParakeetASR.Word]] = []
        for w in windows { out.append(try await asr.transcribe(w)) }
        return out
    }

    static func run(store: URL, wav: URL, seconds: Double) async throws {
        let audio = AnalysisAudio(url: wav)
        let total = min(seconds, audio.duration.seconds)
        func windows(_ len: Double, until end: Double) throws -> [[Float]] {
            stride(from: 0.0, to: end - len, by: len).map { s in
                (try? audio.read(SessionInterval(unchecked: .seconds(s), .seconds(s + len)))) ?? []
            }
        }
        let a = try makeASR(store)
        _ = try await a.transcribe(try audio.read(SessionInterval(unchecked: .seconds(0), .seconds(14.9))))  // warm

        print("== E1: decode cost vs window length (one instance, serial) ==")
        for len in [3.0, 5.0, 8.0, 11.0, 13.0, 14.9] {
            let ws = Array(try windows(len, until: total).prefix(30))
            let t0 = now(); _ = try await decode(a, ws)
            let s = secs(t0)
            print(String(format: "len %5.1fs  calls %3d  %.1f ms/call  %.4f s per audio second", len, ws.count, s / Double(ws.count) * 1000,
                         s / (Double(ws.count) * len)))
        }

        let ws = try windows(13, until: total)
        print("\n== E2: \(ws.count) windows of 13 s ==")
        var t0 = now()
        let serial = try await decode(a, ws)
        let serialS = secs(t0)
        print(String(format: "one instance, serial:            %.2f s", serialS))

        var pool = [a]
        for k in 2...5 {
            let before = footprintMiB()
            let extra = try makeASR(store)
            _ = try await extra.transcribe(ws[0])
            pool.append(extra)
            let added = footprintMiB() - before
            let shards = (0..<k).map { i in stride(from: i, to: ws.count, by: k).map { ws[$0] } }
            t0 = now()
            let outs = try await withThrowingTaskGroup(of: (Int, [[ParakeetASR.Word]]).self) { g in
                for i in 0..<k { let inst = pool[i], sh = shards[i]; g.addTask { (i, try await decode(inst, sh)) } }
                var r: [Int: [[ParakeetASR.Word]]] = [:]
                for try await (i, o) in g { r[i] = o }
                return r
            }
            let parS = secs(t0)
            var merged = [[ParakeetASR.Word]](repeating: [], count: ws.count)
            for i in 0..<k { for (j, o) in outs[i]!.enumerated() { merged[i + j * k] = o } }
            print(String(format: "%d instances: %.2f s  speedup %.2fx  identical: %@  +%.0f MiB for the extra instance (footprint %.0f MiB)", k, parS,
                         serialS / parS, merged == serial ? "yes" : "NO", added, footprintMiB()))
        }

        print("\n== E3: ASR concurrent with diarization (\(Int(audio.duration.seconds)) s file) ==")
        let diar = try FluidDiarizer(directory: store.appending(path: "speaker-diarization-coreml"),
                                     manifestID: ModelManifestID("speaker-diarization-coreml"), revision: "local")
        let token = CancellationToken()
        t0 = now()
        _ = try await diar.analyze(meetingID: MeetingID("bench"), source: .systemOutput, audio: audio, cancellation: token)
        let diarS = secs(t0)
        print(String(format: "diarize alone: %.2f s   ASR alone: %.2f s   sum %.2f s", diarS, serialS, diarS + serialS))
        t0 = now()
        async let dz: Double = { let t = now(); _ = try await diar.analyze(meetingID: MeetingID("bench"), source: .systemOutput, audio: audio, cancellation: token); return secs(t) }()
        async let az: Double = { let t = now(); _ = try await decode(a, ws); return secs(t) }()
        let (d2, a2) = try await (dz, az)
        print(String(format: "concurrent: wall %.2f s (diarize %.2f s, ASR %.2f s)", secs(t0), d2, a2))
    }
}
