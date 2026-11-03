import Foundation

/// The running build's identity (T70), stamped into Info.plist by scripts/stamp-build.sh: the build number is the git
/// commit count, shared by Release and Debug, so a higher number is always a later commit.
public struct BuildInfo: Equatable, Sendable, Codable {
    public enum Channel: String, Sendable, Codable, CaseIterable { case release, debug }

    public var version: String
    public var build: Int
    public var commit: String
    public var dirty: Bool
    public var date: String
    public var channel: Channel

    public init(version: String, build: Int, commit: String, dirty: Bool = false, date: String = "", channel: Channel) {
        self.version = version; self.build = build; self.commit = commit; self.dirty = dirty; self.date = date; self.channel = channel
    }

    /// Reads an Info.plist dictionary; a missing or unstamped build reads as build 0, commit "unknown".
    public init(infoDictionary d: [String: Any]) {
        version = d["CFBundleShortVersionString"] as? String ?? "0"
        build = (d["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
        commit = d["AmaranthCommit"] as? String ?? "unknown"
        dirty = d["AmaranthDirty"] as? Bool ?? false
        date = d["AmaranthBuildDate"] as? String ?? ""
        channel = (d["AmaranthChannel"] as? String).flatMap(Channel.init) ?? .debug
    }

    public static var running: BuildInfo { BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:]) }

    /// "0.1.0 (124)", with " Debug" for the debug channel.
    public var label: String { "\(version) (\(build))" + (channel == .debug ? " Debug" : "") }
    /// "a1b2c3d", or "a1b2c3d, modified" for a build from uncommitted changes.
    public var commitLabel: String { dirty ? "\(commit), modified" : commit }
}
