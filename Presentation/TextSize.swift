public import Foundation

/// Settings → Appearance → Text size (T36). The app's text tokens (`AppStyle`) are multiplied by `scale`; the default
/// is the compact type scale, Larger is for readability and accessibility.
public enum TextSize: String, CaseIterable, Identifiable, Sendable {
    case smaller, `default`, larger

    public static let key = "textSize"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .smaller: "Smaller"
        case .default: "Default"
        case .larger: "Larger"
        }
    }
    public var scale: Double {
        switch self {
        case .smaller: 0.9
        case .default: 1
        case .larger: 1.2
        }
    }
    /// Unknown or missing stored values read as Default.
    public init(stored: String?) { self = stored.flatMap(TextSize.init(rawValue:)) ?? .default }
}
