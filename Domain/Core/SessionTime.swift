public import Foundation

/// A point on a meeting's session timeline, in integer nanoseconds since the session origin.
///
/// The session timeline is derived from hardware host timestamps and per-source sample counters,
/// never from wall-clock time, so NTP or user clock changes cannot move words. Gaps and pauses
/// advance the timeline; they are never collapsed (plan §6 "Timeline").
public struct SessionTime: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var nanoseconds: Int64

    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }
    public static let zero = SessionTime(nanoseconds: 0)

    public static func seconds(_ s: Double) -> SessionTime {
        SessionTime(nanoseconds: Int64((s * 1_000_000_000).rounded()))
    }
    public static func milliseconds(_ ms: Int64) -> SessionTime { SessionTime(nanoseconds: ms * 1_000_000) }

    /// Exact time of `frame` at `sampleRate`, relative to an epoch starting at `self`.
    /// Integer arithmetic avoids accumulated floating-point drift over multi-hour sessions.
    public func advanced(byFrames frame: Int64, sampleRate: Int) -> SessionTime {
        precondition(sampleRate > 0)
        let whole = frame / Int64(sampleRate)
        let rem = frame % Int64(sampleRate)
        return SessionTime(nanoseconds: nanoseconds + whole * 1_000_000_000 + rem * 1_000_000_000 / Int64(sampleRate))
    }

    public var seconds: Double { Double(nanoseconds) / 1_000_000_000 }

    public static func < (a: Self, b: Self) -> Bool { a.nanoseconds < b.nanoseconds }
    public static func + (a: Self, b: SessionDuration) -> Self { SessionTime(nanoseconds: a.nanoseconds + b.nanoseconds) }
    public static func - (a: Self, b: Self) -> SessionDuration { SessionDuration(nanoseconds: a.nanoseconds - b.nanoseconds) }
    /// Shifts earlier on the timeline, clamped at the session origin.
    public static func - (a: Self, b: SessionDuration) -> Self { SessionTime(nanoseconds: max(0, a.nanoseconds - b.nanoseconds)) }

    public init(from decoder: any Decoder) throws {
        nanoseconds = try decoder.singleValueContainer().decode(Int64.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(nanoseconds)
    }

    public var description: String {
        let totalMs = nanoseconds / 1_000_000
        let ms = totalMs % 1000, s = (totalMs / 1000) % 60, m = (totalMs / 60_000) % 60, h = totalMs / 3_600_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", h, m, s, ms)
    }
}

public struct SessionDuration: Hashable, Sendable, Codable, Comparable {
    public var nanoseconds: Int64
    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }
    public static func seconds(_ s: Double) -> SessionDuration { SessionDuration(nanoseconds: Int64((s * 1e9).rounded())) }
    public var seconds: Double { Double(nanoseconds) / 1e9 }
    public static func < (a: Self, b: Self) -> Bool { a.nanoseconds < b.nanoseconds }

    public init(from decoder: any Decoder) throws {
        nanoseconds = try decoder.singleValueContainer().decode(Int64.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(nanoseconds)
    }
}

/// Half-open interval `[start, end)` on the session timeline.
public struct SessionInterval: Hashable, Sendable, Codable, CustomStringConvertible {
    public let start: SessionTime
    public let end: SessionTime

    public init(start: SessionTime, end: SessionTime) throws {
        guard end >= start else { throw DomainError.invalidInterval(start: start.nanoseconds, end: end.nanoseconds) }
        self.start = start
        self.end = end
    }

    /// For literals in fixtures/tests where validity is known.
    public init(unchecked start: SessionTime, _ end: SessionTime) {
        precondition(end >= start, "invalid interval")
        self.start = start
        self.end = end
    }

    public static func seconds(_ a: Double, _ b: Double) -> SessionInterval {
        SessionInterval(unchecked: .seconds(a), .seconds(b))
    }

    public var duration: SessionDuration { end - start }
    public var isEmpty: Bool { start == end }

    public func overlaps(_ other: SessionInterval) -> Bool { start < other.end && other.start < end }

    public func intersection(_ other: SessionInterval) -> SessionInterval? {
        let s = max(start, other.start), e = min(end, other.end)
        return s < e ? SessionInterval(unchecked: s, e) : nil
    }

    public func contains(_ t: SessionTime) -> Bool { t >= start && t < end }

    private enum CodingKeys: String, CodingKey { case start, end }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: c.decode(SessionTime.self, forKey: .start), end: c.decode(SessionTime.self, forKey: .end))
    }

    public var description: String { "[\(start), \(end))" }
}

/// Wall-clock metadata kept separately from the session timeline, for display only.
public struct SessionClock: Hashable, Sendable, Codable {
    /// UTC instant corresponding to `SessionTime.zero`.
    public var utcOrigin: Date
    /// IANA time-zone identifier at session start, e.g. "America/Los_Angeles".
    public var timeZoneIdentifier: String
    /// Mach host time (in nanoseconds) corresponding to `SessionTime.zero`.
    public var hostTimeOriginNanos: UInt64

    public init(utcOrigin: Date, timeZoneIdentifier: String, hostTimeOriginNanos: UInt64) {
        self.utcOrigin = utcOrigin
        self.timeZoneIdentifier = timeZoneIdentifier
        self.hostTimeOriginNanos = hostTimeOriginNanos
    }

    public func displayDate(for t: SessionTime) -> Date { utcOrigin.addingTimeInterval(t.seconds) }
}
