import Foundation

/// Display-oriented status that keeps capture and processing independent: a meeting can be fully
/// captured while its notes failed, and the UI must say both things.
public struct MeetingStatus: Hashable, Sendable {
    public enum AudioHeadline: Hashable, Sendable {
        case notStarted, recording, paused, saving
        case saved
        case savedWithGaps(missingSeconds: Double)
        case interrupted
        case audioDeleted
    }

    public enum ProcessingHeadline: Hashable, Sendable {
        case notQueued
        case waiting(SuspensionReason?)
        case running(ProcessingStage, progress: Double)
        case complete
        /// Some stage failed; earlier stage outputs (e.g. transcript) may still be usable.
        case failed(ProcessingStage, errorCode: String?)
        case cancelled(ProcessingStage)
    }

    public var audio: AudioHeadline
    public var processing: ProcessingHeadline
    public var stages: [ProcessingStage: ProcessingState]

    public init(meeting: Meeting, jobs: [ProcessingJob], events: [CaptureEvent]) {
        let missing = MeetingStatus.missingSeconds(events)
        if meeting.audio == .deletedByUser {
            audio = .audioDeleted
        } else {
            switch meeting.captureState {
            case .idle: audio = .notStarted
            case .preparing, .recording: audio = .recording
            case .paused: audio = .paused
            case .stopping: audio = .saving
            case .captured: audio = missing > 0 ? .savedWithGaps(missingSeconds: missing) : .saved
            case .capturedWithGaps: audio = .savedWithGaps(missingSeconds: missing)
            case .interrupted: audio = .interrupted
            }
        }

        // Latest job per stage wins.
        var latest: [ProcessingStage: ProcessingJob] = [:]
        for j in jobs where j.key.meetingID == meeting.id && j.key.stage != .live {
            if let cur = latest[j.key.stage], cur.updatedAt > j.updatedAt { continue }
            latest[j.key.stage] = j
        }
        stages = latest.mapValues(\.state)

        let order: [ProcessingStage] = [.prepare, .transcribe, .diarize, .reconcile, .notes]
        if latest.isEmpty {
            processing = .notQueued
        } else if let f = order.compactMap({ latest[$0] }).first(where: { $0.state == .failed }) {
            processing = .failed(f.key.stage, errorCode: f.errorCode)
        } else if let r = order.compactMap({ latest[$0] }).first(where: { $0.state == .running }) {
            processing = .running(r.key.stage, progress: r.progress)
        } else if let c = order.compactMap({ latest[$0] }).first(where: { $0.state == .cancelled }) {
            processing = .cancelled(c.key.stage)
        } else if let w = order.compactMap({ latest[$0] }).first(where: { $0.state == .queued || $0.state == .suspended }) {
            processing = .waiting(w.suspension)
        } else if latest[.notes]?.state == .succeeded {
            processing = .complete
        } else {
            processing = .waiting(nil)
        }
    }

    /// Union of missing-audio intervals per source (overlapping events, e.g. a device fault and the writer's exact gap,
    /// are not double-counted). Meeting-wide events count once.
    public static func missingSeconds(_ events: [CaptureEvent]) -> Double {
        var bySource: [String: [SessionInterval]] = [:]
        for e in events where e.isMissingAudio { bySource[e.source?.rawValue ?? "all", default: []].append(e.interval) }
        var total = 0.0
        for ivs in bySource.values {
            var merged: [SessionInterval] = []
            for iv in ivs.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, iv.start <= last.end {
                    merged[merged.count - 1] = SessionInterval(unchecked: last.start, max(last.end, iv.end))
                } else { merged.append(iv) }
            }
            total = max(total, merged.reduce(0.0) { $0 + $1.duration.seconds })
        }
        return total
    }

    /// True when audio is safely on disk regardless of processing outcome.
    public var audioIsSaved: Bool {
        switch audio {
        case .saved, .savedWithGaps: true
        default: false
        }
    }
}
