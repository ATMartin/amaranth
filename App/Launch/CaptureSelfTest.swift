import AVFoundation
import CoreAudio
import Foundation
import Capture
import Domain

/// Real-hardware capture verification under the app's bundle identity (T03). Launch through LaunchServices so TCC
/// attributes permissions to Amaranth rather than Terminal:
///   open -W -n Amaranth.app --args --self-test capture-signals --self-test-output /path/out.jsonl
@MainActor
enum CaptureSelfTest {
    static var root: URL {
        FileManager.default.temporaryDirectory.appending(path: "amaranth-capture-selftest")
    }

    /// Plays tones from a separate process (must be captured), from Amaranth itself (must NOT be captured by the
    /// system tap), and from a process started mid-recording (must be captured). Then checks latency gates.
    static func signals() async -> Bool {
        let log = SelfTest.log
        let micStatus = HALInputSource.authorizationStatus()
        log(["step": "permissions", "microphone": "\(micStatus.rawValue)"])
        if micStatus == .notDetermined { _ = await HALInputSource.requestAccess() }
        let (probe, detail) = await SystemAudioPermissionProbe.run()
        log(["step": "systemAudioPermission", "result": probe.rawValue, "detail": detail])
        let defaultOutBefore = defaultDeviceUID(input: false), defaultInBefore = defaultDeviceUID(input: true)

        let dir = root.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toneA = dir.appending(path: "tone-1000.caf"), toneB = dir.appending(path: "tone-1500.caf"), self660 = dir.appending(path: "tone-660.caf")
        writeTone(hz: 1000, seconds: 1.5, to: toneA)
        writeTone(hz: 1500, seconds: 1.5, to: toneB)
        writeTone(hz: 660, seconds: 1.5, to: self660)

        let session: RecordingSession
        let pressedRecord = HostClock.nowNanos()
        do {
            session = try RecordingSession(meetingID: MeetingID(), rootDirectory: dir, options: RecordingOptions(selection: .both))
            try session.start()
        } catch {
            log(["step": "start", "error": "\(error)"])
            return false
        }
        let startErrors = session.snapshot().startErrors
        log(["step": "start", "state": session.state.rawValue, "startErrors": "\(startErrors)"])

        // Tone schedule on the session timeline.
        try? await Task.sleep(for: .seconds(1.0))
        let tA = session.now
        let pA = try? Process.run(URL(filePath: "/usr/bin/afplay"), arguments: [toneA.path])
        try? await Task.sleep(for: .seconds(2.0))
        let tSelf = session.now
        let player = try? AVAudioPlayer(contentsOf: self660)
        player?.play()
        try? await Task.sleep(for: .seconds(2.0))
        let tB = session.now
        // A process launched after recording began.
        let pB = try? Process.run(URL(filePath: "/usr/bin/afplay"), arguments: [toneB.path])
        try? await Task.sleep(for: .seconds(2.0))
        let health = session.health()
        let result = session.stop()
        pA?.waitUntilExit(); pB?.waitUntilExit()

        // Latency gates (from pressing Record to first frames at the writer / first committed segment).
        var ok = true
        for kind in SourceKind.allCases {
            guard let ws = result.writerStats[kind] else { continue }
            let firstFrame = ws.firstFrameHostNanos.map { Double($0 - pressedRecord) / 1e9 } ?? -1
            let firstCommit = ws.firstCommitHostNanos.map { Double($0 - pressedRecord) / 1e9 } ?? -1
            let rs = result.ringStats[kind]
            let fmt = result.epochs.first { $0.source == kind }?.format
            let callbacks = max(rs?.callbacks ?? 1, 1)
            let framesPerCallback = Double(rs?.framesPushed ?? 0) / Double(callbacks)
            let bufferNs = fmt.map { framesPerCallback / Double($0.sampleRate) * 1e9 } ?? 0
            let p99 = rs?.callbackPercentileNanos(0.99) ?? 0
            let gate = firstFrame >= 0 && firstFrame <= 2 && firstCommit >= 0 && firstCommit <= 4
            ok = ok && gate
            log(["step": "latency", "source": kind.rawValue, "firstFrameSec": String(format: "%.3f", firstFrame),
                 "firstCommitSec": String(format: "%.3f", firstCommit), "gate": gate ? "pass" : "fail",
                 "format": fmt?.description ?? "-", "device": health.first { $0.source == kind }?.deviceName ?? "-",
                 "callbacks": "\(rs?.callbacks ?? 0)", "framesPerCallback": String(format: "%.0f", framesPerCallback),
                 "callbackP99us": "\(p99 / 1000)", "callbackMaxUs": "\((rs?.maxCallbackNanos ?? 0) / 1000)",
                 "bufferUs": String(format: "%.0f", bufferNs / 1000),
                 "p99UnderTenPercent": "\(Double(p99) < bufferNs * 0.1)",
                 "overrunFrames": "\(rs?.overrunFrames ?? 0)", "formatMismatch": "\(rs?.formatMismatchCallbacks ?? 0)",
                 "maxDriftMs": String(format: "%.2f", Double(ws.maxDriftNanos) / 1e6)])
        }

        // Known-signal analysis.
        func window(_ t: SessionTime) -> SessionInterval { SessionInterval(unchecked: t + .seconds(0.4), t + .seconds(1.2)) }
        for kind in SourceKind.allCases {
            let segs = result.segments.filter { $0.source == kind }
            guard let track = try? SignalAnalysis.track(segments: segs, directory: result.directory) else {
                log(["step": "signal", "source": kind.rawValue, "error": "no audio"]); ok = false; continue
            }
            let a = SignalAnalysis.toneLevelDB(track.slice(window(tA)), hz: 1000, sampleRate: track.sampleRate)
            let s = SignalAnalysis.toneLevelDB(track.slice(window(tSelf)), hz: 660, sampleRate: track.sampleRate)
            let b = SignalAnalysis.toneLevelDB(track.slice(window(tB)), hz: 1500, sampleRate: track.sampleRate)
            let base = SignalAnalysis.rmsDB(track.slice(SessionInterval(unchecked: .seconds(0.2), tA)))
            var fields = ["step": "signal", "source": kind.rawValue, "tone1000dB": f(a), "self660dB": f(s), "tone1500dB": f(b),
                          "baselineRmsDB": f(base), "missingFraction": String(format: "%.4f", track.missingFraction)]
            if kind == .systemOutput {
                let captured = a > -30 && b > -30
                let selfExcluded = s < -60
                fields["externalCaptured"] = "\(captured)"
                fields["selfExcluded"] = "\(selfExcluded)"
                ok = ok && captured && selfExcluded
            } else {
                // The mic hears the room: tones appear only if played through speakers. Require live, non-zero input.
                fields["micLive"] = "\(base > -120)"
                ok = ok && base > -120
            }
            log(fields)
        }
        let routesUnchanged = defaultDeviceUID(input: false) == defaultOutBefore && defaultDeviceUID(input: true) == defaultInBefore
        log(["step": "routes", "defaultOutput": defaultOutBefore ?? "-", "defaultInput": defaultInBefore ?? "-", "unchanged": "\(routesUnchanged)"])
        log(["step": "events", "count": "\(result.events.count)", "kinds": result.events.map { "\($0.kind.rawValue):\($0.reasonCode)" }.joined(separator: ",")])
        log(["step": "artifacts", "directory": result.directory.path])
        return ok && routesUnchanged && result.events.filter(\.isMissingAudio).isEmpty
    }

    /// Long capture with periodic resource sampling: overruns, callback p99, footprint growth and CPU.
    static func soak(minutes: Double) async -> Bool {
        let log = SelfTest.log
        let dir = root.appending(path: "soak-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session: RecordingSession
        do {
            session = try RecordingSession(meetingID: MeetingID(), rootDirectory: dir, options: RecordingOptions(selection: .both))
            try session.start()
        } catch { log(["step": "start", "error": "\(error)"]); return false }
        let cpu0 = ProcessMetrics.cpuSeconds(), t0 = Date()
        var footprints: [(Double, UInt64)] = []
        while Date().timeIntervalSince(t0) < minutes * 60 {
            try? await Task.sleep(for: .seconds(30))
            let elapsed = Date().timeIntervalSince(t0)
            let fp = ProcessMetrics.physicalFootprint()
            footprints.append((elapsed, fp))
            let snap = session.snapshot()
            log(["step": "sample", "elapsedSec": String(format: "%.0f", elapsed), "footprintMiB": String(format: "%.1f", Double(fp) / 1_048_576),
                 "cpuPercentAvg": String(format: "%.2f", (ProcessMetrics.cpuSeconds() - cpu0) / elapsed * 100),
                 "segments": "\(snap.segments.count)", "events": "\(snap.events.count)",
                 "overruns": "\(snap.ringStats.values.map(\.overrunFrames).reduce(0, +))"])
        }
        let cpu = (ProcessMetrics.cpuSeconds() - cpu0) / Date().timeIntervalSince(t0) * 100
        let r = session.stop()
        var ok = true
        for kind in SourceKind.allCases {
            guard let rs = r.ringStats[kind], let fmt = r.epochs.first(where: { $0.source == kind })?.format else { continue }
            let bufferNs = Double(rs.framesPushed) / Double(max(rs.callbacks, 1)) / Double(fmt.sampleRate) * 1e9
            let p99 = Double(rs.callbackPercentileNanos(0.99))
            let pass = rs.overrunFrames == 0 && p99 < bufferNs * 0.1
            ok = ok && pass
            log(["step": "soakSource", "source": kind.rawValue, "overrunFrames": "\(rs.overrunFrames)", "callbackP99us": String(format: "%.0f", p99 / 1000),
                 "bufferUs": String(format: "%.0f", bufferNs / 1000), "maxCallbackUs": "\(rs.maxCallbackNanos / 1000)",
                 "segments": "\(r.segments.filter { $0.source == kind }.count)", "maxDriftMs": String(format: "%.2f", Double(r.writerStats[kind]?.maxDriftNanos ?? 0) / 1e6),
                 "maxCommitLatencyMs": String(format: "%.1f", Double(r.writerStats[kind]?.maxCommitLatencyNanos ?? 0) / 1e6),
                 "maxIOQueueDepth": "\(r.writerStats[kind]?.maxIOQueueDepth ?? 0)", "pass": "\(pass)"])
        }
        let peak = footprints.map(\.1).max() ?? 0
        let missing = r.events.filter(\.isMissingAudio)
        log(["step": "soakSummary", "minutes": String(format: "%.1f", minutes), "cpuPercentAvg": String(format: "%.2f", cpu),
             "peakFootprintMiB": String(format: "%.1f", Double(peak) / 1_048_576), "missingAudioEvents": "\(missing.count)",
             "eventKinds": r.events.map { "\($0.kind.rawValue):\($0.reasonCode)" }.joined(separator: ","), "directory": r.directory.path])
        return ok && missing.isEmpty && cpu < 15 && Double(peak) < 350 * 1_048_576
    }

    /// Route changes mid-recording: default output → another output and back, then default input → an input with a
    /// different sample rate and back. Original defaults are always restored.
    static func routes() async -> Bool {
        let log = SelfTest.log
        guard let outBefore = AudioDevices.defaultOutputUID(), let inBefore = AudioDevices.defaultInputUID() else { return false }
        defer {
            AudioDevices.setDefault(input: false, uid: outBefore)
            AudioDevices.setDefault(input: true, uid: inBefore)
        }
        let outputs = AudioDevices.outputs(), inputs = AudioDevices.inputs()
        let currentInRate = inputs.first { $0.uid == inBefore }?.sampleRate ?? 0
        // Prefer an inaudible virtual output; otherwise any other output.
        guard let altOut = outputs.first(where: { $0.uid != outBefore && $0.transport == kAudioDeviceTransportTypeVirtual })
                ?? outputs.first(where: { $0.uid != outBefore }) else { log(["step": "routes", "error": "no alternate output"]); return false }
        let altIn = inputs.first { $0.uid != inBefore && $0.sampleRate != currentInRate } ?? inputs.first { $0.uid != inBefore }
        log(["step": "routePlan", "output": outBefore, "altOutput": "\(altOut.name) (\(altOut.transportName), \(Int(altOut.sampleRate)) Hz)",
             "input": inBefore, "altInput": altIn.map { "\($0.name) (\($0.transportName), \(Int($0.sampleRate)) Hz)" } ?? "none"])

        let dir = root.appending(path: "routes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tones = [(1000.0, "a"), (1500.0, "b"), (2000.0, "c")].map { hz, n -> (Double, URL) in
            let u = dir.appending(path: "tone-\(n).caf"); writeTone(hz: hz, seconds: 1.2, to: u); return (hz, u)
        }
        let session: RecordingSession
        do {
            session = try RecordingSession(meetingID: MeetingID(), rootDirectory: dir, options: RecordingOptions(selection: .both))
            try session.start()
        } catch { log(["step": "start", "error": "\(error)"]); return false }

        func play(_ i: Int) -> SessionTime {
            let t = session.now
            let p = try? Process.run(URL(filePath: "/usr/bin/afplay"), arguments: [tones[i].1.path])
            _ = p
            return t
        }
        try? await Task.sleep(for: .seconds(1)); let tA = play(0)
        try? await Task.sleep(for: .seconds(1.5)); let tOut = session.now; AudioDevices.setDefault(input: false, uid: altOut.uid)
        try? await Task.sleep(for: .seconds(1)); let tB = play(1)
        try? await Task.sleep(for: .seconds(2)); AudioDevices.setDefault(input: false, uid: outBefore)
        try? await Task.sleep(for: .seconds(1)); let tC = play(2)
        try? await Task.sleep(for: .seconds(2))
        var tIn: SessionTime?
        if let altIn { tIn = session.now; AudioDevices.setDefault(input: true, uid: altIn.uid) }
        try? await Task.sleep(for: .seconds(2)); AudioDevices.setDefault(input: true, uid: inBefore)
        try? await Task.sleep(for: .seconds(1.5))
        let r = session.stop()

        var ok = true
        let sysSegs = r.segments.filter { $0.source == .systemOutput }
        if let track = try? SignalAnalysis.track(segments: sysSegs, directory: r.directory) {
            for (i, t) in [tA, tB, tC].enumerated() {
                let lvl = SignalAnalysis.toneLevelDB(track.slice(SessionInterval(unchecked: t + .seconds(0.4), t + .seconds(1.0))),
                                                     hz: tones[i].0, sampleRate: track.sampleRate)
                let captured = lvl > -30
                ok = ok && captured
                log(["step": "routeTone", "tone": "\(Int(tones[i].0))", "phase": ["default output", "alternate output", "restored output"][i],
                     "levelDB": f(lvl), "captured": "\(captured)"])
            }
        } else { ok = false }
        for kind in SourceKind.allCases {
            let eps = r.epochs.filter { $0.source == kind }
            log(["step": "routeEpochs", "source": kind.rawValue,
                 "epochs": eps.map { "\($0.index):\($0.reason.rawValue)@\($0.sessionStart):\($0.format)" }.joined(separator: " | ")])
        }
        // Recovery time: each deviceChange must be followed by recovery within 5 s (plan §10 route gate).
        let faults = r.events.filter { $0.kind == .sourceFault }
        for e in faults { ok = ok && e.interval.duration.seconds <= 5 }
        let micFormats = Set(r.epochs.filter { $0.source == .microphone }.map(\.format.sampleRate))
        if let altIn, altIn.sampleRate != currentInRate { ok = ok && micFormats.count >= 2 }
        log(["step": "routeEvents", "outputSwitchAt": "\(tOut)", "inputSwitchAt": tIn.map { "\($0)" } ?? "-",
             "events": r.events.map { "\($0.source?.rawValue ?? "all"):\($0.kind.rawValue):\($0.reasonCode):\(String(format: "%.3f", $0.interval.duration.seconds))s" }.joined(separator: ", "),
             "missingSeconds": String(format: "%.3f", MeetingStatus.missingSeconds(r.events)), "finalState": r.finalState.rawValue,
             "micSampleRates": micFormats.sorted().map(String.init).joined(separator: ",")])
        let restored = AudioDevices.defaultOutputUID() == outBefore
        log(["step": "routeRestore", "outputRestored": "\(restored)"])
        return ok
    }

    /// Records for `seconds` and reports whether a tone at `hz` appeared in the system track (for external players such
    /// as browsers or meeting apps driven by Benchmarks/Capture/app-matrix.sh). Also reports the mic so a talker can be checked.
    static func tone(hz: Double, seconds: Double, label: String, selection: SourceSelection = .systemOnly) async -> Bool {
        let log = SelfTest.log
        let dir = root.appending(path: "tone-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session: RecordingSession
        do {
            session = try RecordingSession(meetingID: MeetingID(), rootDirectory: dir, options: RecordingOptions(selection: selection))
            try session.start()
        } catch { log(["step": "start", "error": "\(error)"]); return false }
        log(["step": "recording", "label": label, "seconds": "\(seconds)"])
        try? await Task.sleep(for: .seconds(seconds))
        let r = session.stop()
        guard let track = try? SignalAnalysis.track(segments: r.segments.filter { $0.source == .systemOutput }, directory: r.directory) else {
            log(["step": "tone", "error": "no system audio"]); return false
        }
        var levels: [Double] = []
        var t = 0.0
        while t + 0.5 <= seconds {
            levels.append(SignalAnalysis.toneLevelDB(track.slice(.seconds(t, t + 0.5)), hz: hz, sampleRate: track.sampleRate))
            t += 0.5
        }
        let present = levels.filter { $0 > -45 }.count
        let micTrack = try? SignalAnalysis.track(segments: r.segments.filter { $0.source == .microphone }, directory: r.directory)
        log(["step": "tone", "label": label, "hz": "\(Int(hz))", "maxLevelDB": f(levels.max() ?? -200),
             "windowsWithTone": "\(present)/\(levels.count)", "micRmsDB": f(micTrack.map { SignalAnalysis.rmsDB($0.samples.filter { !$0.isNaN }[...]) } ?? -200),
             "missingAudioEvents": "\(r.events.filter(\.isMissingAudio).count)", "directory": r.directory.path])
        return present > 0
    }

    static func f(_ v: Double) -> String { String(format: "%.1f", v) }

    static func writeTone(hz: Double, seconds: Double, to url: URL) {
        let rate = 48_000
        let samples = (0..<Int(Double(rate) * seconds)).map { i -> Float in
            let env = Float(min(1, min(Double(i), Double(Int(Double(rate) * seconds) - i)) / 480)) // 10 ms fades
            return 0.3 * env * Float(sin(2 * .pi * hz * Double(i) / Double(rate)))
        }
        let data = samples.withUnsafeBufferPointer { CAFFile.encode(samples: $0, format: AudioFormat(sampleRate: rate, channelCount: 1, sampleFormat: .float32)) }
        try? data.write(to: url)
    }

    static func defaultDeviceUID(input: Bool) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
