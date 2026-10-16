import Foundation
import Capture
import Domain
import Storage

// Child recorder for force-kill tests: records synthetic mic (48 kHz mono) + system (48 kHz stereo) in realtime into a
// MeetingStore at <root>, prints "STARTED <meetingID> <sessionOriginHostNanos>", and runs until killed.
setvbuf(stdout, nil, _IOLBF, 0)

// `--long <root>`: the T05 two-hour session (60× synthetic, ±50 ppm clocks, markers every 600 s) in its own process, so
// its memory footprint is not contaminated by other test suites. Prints "LONG <meetingID> <growthMiB> <maxMiB>".
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--long" {
    let root = URL(filePath: CommandLine.arguments[2])
    let store = try MeetingStore(root: root)
    let fmt = AudioFormat(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32)
    let ppm: [SourceKind: Double] = [.microphone: 50, .systemOutput: -50]
    func markerFrames(_ p: Double) -> Set<Int64> { Set((1...11).map { Int64((Double($0) * 600 / (1 + p / 1e6) * 16_000).rounded()) }) }
    let id = MeetingID()
    let s = try RecordingSession(meetingID: id, rootDirectory: root, options: RecordingOptions(selection: .both), store: store, title: "long") { kind in
        let marks = markerFrames(ppm[kind]!)
        var plan = SyntheticSource.Plan(format: fmt, callbackFrames: 512, speed: 60) { i, _ in marks.contains(i) ? 1.0 : 0.001 * Float(sin(Double(i) * 0.05)) }
        plan.hostClockPPM = ppm[kind]!
        return SyntheticSource(kind: kind, plan: plan)
    }
    try s.start()
    while s.state != .recording { Thread.sleep(forTimeInterval: 0.01) }
    var at15: UInt64 = 0, maxFP: UInt64 = 0
    let t0 = Date()
    while Date().timeIntervalSince(t0) < 2 * 3600 / 60.0 {
        Thread.sleep(forTimeInterval: 1)
        let fp = ProcessMetrics.physicalFootprint()
        maxFP = max(maxFP, fp)
        if at15 == 0, Date().timeIntervalSince(t0) >= 15 { at15 = fp }
    }
    let end = ProcessMetrics.physicalFootprint()
    _ = s.stop()
    print("LONG \(id.rawValue) \(Double(Int64(end) - Int64(at15)) / 1_048_576) \(Double(maxFP) / 1_048_576)")
    exit(0)
}

let root = URL(filePath: CommandLine.arguments[1])
let store = try MeetingStore(root: root)
let mono = AudioFormat(sampleRate: 48_000, channelCount: 1, sampleFormat: .float32)
let stereo = AudioFormat(sampleRate: 48_000, channelCount: 2, sampleFormat: .float32)
let id = MeetingID()
let session = try RecordingSession(meetingID: id, rootDirectory: root, options: RecordingOptions(selection: .both), store: store,
                                   title: "force-kill child") { kind in
    SyntheticSource(kind: kind, plan: kind == .microphone ? .sine(440, format: mono) : .sine(660, format: stereo))
}
try session.start()
while session.state != .recording { Thread.sleep(forTimeInterval: 0.01) }
print("STARTED \(id.rawValue) \(session.clock.hostTimeOriginNanos)")
RunLoop.main.run()
