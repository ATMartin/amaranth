public import Domain

/// Maps positions in a source's committed audio onto the shared host-clock session timeline (plan §6 "Timeline").
///
/// Each segment's `interval` comes from the device sample count; `observedStart` is the host-clock time of its first
/// frame. Within an epoch, frames are mapped by linear interpolation between consecutive segments' observed starts, so
/// device-clock drift (tens of ppm, hundreds of ms over hours) is removed while short-term jitter is averaged out.
/// Segments without an observed start (older recordings) fall back to the sample-count timeline.
public struct TimelineNormalizer: Sendable {
    private let segments: [AudioSegmentRecord]

    /// `segments` for a single source, any order.
    public init(segments: [AudioSegmentRecord]) {
        self.segments = segments.sorted { $0.sequence < $1.sequence }
    }

    /// Host-timeline position of `frame` frames into `segment`.
    public func time(segment: AudioSegmentRecord, frame: Int64) -> SessionTime {
        guard let i = segments.firstIndex(where: { $0.id == segment.id }), let a = segment.observedStart else {
            return segment.interval.start.advanced(byFrames: frame, sampleRate: segment.format.sampleRate)
        }
        // Anchor pair: this segment's start and the next contiguous segment's start in the same epoch.
        let next = i + 1 < segments.count ? segments[i + 1] : nil
        if let n = next, n.epochID == segment.epochID, let b = n.observedStart,
           n.firstFrameInEpoch == segment.firstFrameInEpoch + segment.frameCount, b > a {
            let span = Double(b.nanoseconds - a.nanoseconds)
            return SessionTime(nanoseconds: a.nanoseconds + Int64((span * Double(frame) / Double(segment.frameCount)).rounded()))
        }
        // Last segment of an epoch: extrapolate with the previous pair's rate when available.
        if i > 0, segments[i - 1].epochID == segment.epochID, let p = segments[i - 1].observedStart, a > p {
            let rate = Double(a.nanoseconds - p.nanoseconds) / Double(segments[i - 1].frameCount)
            return SessionTime(nanoseconds: a.nanoseconds + Int64((rate * Double(frame)).rounded()))
        }
        return a.advanced(byFrames: frame, sampleRate: segment.format.sampleRate)
    }

    /// Host-timeline position of a sample-count session time (inverse lookup through the covering segment).
    public func time(atSampleTime t: SessionTime) -> SessionTime {
        guard let seg = segments.first(where: { $0.interval.contains(t) }) else { return t }
        let frame = (t - seg.interval.start).nanoseconds * Int64(seg.format.sampleRate) / 1_000_000_000
        return time(segment: seg, frame: frame)
    }
}
