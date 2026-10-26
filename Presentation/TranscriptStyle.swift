public import Foundation

/// Settings → Appearance → Transcript style (T37). Columns (T35) is the default; Bubbles is an exploration.
public enum TranscriptStyle: String, CaseIterable, Identifiable, Sendable {
    case columns, bubbles

    public static let key = "transcriptStyle"
    public var id: String { rawValue }
    public var title: String { self == .columns ? "Columns" : "Bubbles" }
    /// Unknown or missing stored values read as Columns.
    public init(stored: String?) { self = stored.flatMap(TranscriptStyle.init(rawValue:)) ?? .columns }
}
