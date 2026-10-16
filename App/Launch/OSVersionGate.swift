import Foundation

/// Full runtime OS check (LSMinimumSystemVersion cannot be relied on for the patch component in every launch path).
enum OSVersionGate {
    static let minimum = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 2)

    static var isSupported: Bool { ProcessInfo.processInfo.isOperatingSystemAtLeast(minimum) }

    static var isSupportedArchitecture: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static var currentDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
