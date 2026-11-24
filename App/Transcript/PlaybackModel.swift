import AVFoundation
import Foundation
import Observation
import Domain

/// Click-to-play over the original CAF segments. Each source gets a player node; segments are converted to one
/// playback format and scheduled at their session times a few seconds ahead, so gaps stay silent at their true
/// positions and a two-hour meeting never loads into memory.
@MainActor @Observable
final class PlaybackModel {
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var error: String?
    private let engine = AVAudioEngine()
    private var nodes: [SourceKind: AVAudioPlayerNode] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var segments: [SourceKind: [AudioSegmentRecord]] = [:]
    private var directory: URL?
    private var origin: Double = 0           // session seconds at player sample time 0
    private var cursor: [SourceKind: Int] = [:]
    private var timer: Timer?
    private let lookahead = 8.0

    func load(meetingDirectory: URL, segments all: [AudioSegmentRecord]) {
        stop()
        directory = meetingDirectory
        segments = Dictionary(grouping: all.filter { $0.state == .committed }, by: \.source).mapValues { $0.sorted { $0.interval.start < $1.interval.start } }
        position = 0
    }

    func play(from t: Double) {
        stop()
        guard directory != nil, !segments.isEmpty else { return }
        error = nil
        for kind in segments.keys where nodes[kind] == nil {
            let n = AVAudioPlayerNode()
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: format)
            nodes[kind] = n
        }
        do { try engine.start() } catch { self.error = "Playback unavailable: \(error.localizedDescription)"; return }
        origin = t
        for (kind, list) in segments { cursor[kind] = list.firstIndex { $0.interval.end.seconds > t } ?? list.count }
        schedule()
        for n in nodes.values { n.play() }
        isPlaying = true
        position = t
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPlayback() }
        }
    }

    func toggle() { isPlaying ? pause() : play(from: position) }

    /// The scrubber: moves the play position; keeps playing from there if it was playing.
    func seek(to t: Double) {
        if isPlaying { play(from: t) } else { position = max(0, t) }
    }

    func pause() { stop() }

    func stop() {
        timer?.invalidate(); timer = nil
        for n in nodes.values { n.stop() }
        if engine.isRunning { engine.stop() }
        isPlaying = false
    }

    private func tickPlayback() {
        guard let n = nodes.values.first, let rt = n.lastRenderTime, let pt = n.playerTime(forNodeTime: rt) else { return }
        position = origin + Double(pt.sampleTime) / pt.sampleRate
        schedule()
        let end = segments.values.compactMap { $0.last?.interval.end.seconds }.max() ?? 0
        if position >= end { stop(); position = end }
    }

    /// Schedules segments that start before `position + lookahead`.
    private func schedule() {
        guard let directory else { return }
        let horizon = max(position, origin) + lookahead
        for (kind, list) in segments {
            guard let node = nodes[kind] else { continue }
            var i = cursor[kind] ?? list.count
            while i < list.count, list[i].interval.start.seconds < horizon {
                let seg = list[i]
                i += 1
                guard let buffer = try? convertedBuffer(directory.appending(path: seg.relativePath)) else { continue }
                // Trim the part before the play position for the first segment.
                let skip = max(0, origin - seg.interval.start.seconds)
                let startFrame = AVAudioFramePosition(skip * format.sampleRate)
                guard startFrame < AVAudioFramePosition(buffer.frameLength) else { continue }
                let at = max(0, seg.interval.start.seconds - origin)
                if startFrame > 0 {
                    let rest = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - startFrame)
                    guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: rest) else { continue }
                    tail.frameLength = rest
                    for c in 0..<Int(format.channelCount) {
                        tail.floatChannelData![c].update(from: buffer.floatChannelData![c].advanced(by: Int(startFrame)), count: Int(rest))
                    }
                    node.scheduleBuffer(tail, at: AVAudioTime(sampleTime: AVAudioFramePosition(at * format.sampleRate), atRate: format.sampleRate))
                } else {
                    node.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition(at * format.sampleRate), atRate: format.sampleRate))
                }
            }
            cursor[kind] = i
        }
    }

    private func convertedBuffer(_ url: URL) throws -> AVAudioPCMBuffer? {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: input)
        if file.processingFormat == format { return input }
        guard let conv = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        if file.processingFormat.channelCount == 1 { conv.channelMap = [0, 0] }   // mono → both ears
        let cap = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let err { throw err }
        return out
    }
}
