public import Foundation
import CryptoKit

// T72: checks on a downloaded build before it may replace the installed app. Builds aren't notarized (free personal
// team), so these checks are what stands between a download and /Applications.

/// What the installer read from the downloaded, unzipped bundle (signature via the Security framework).
public struct UpdateBundleFacts: Equatable, Sendable {
    public var signatureValid: Bool
    public var bundleID: String?
    public var teamID: String?
    public var build: Int?
    public var channel: String?
    public var minimumSystemVersion: String?
    public var architectures: [String]

    public init(signatureValid: Bool, bundleID: String?, teamID: String?, build: Int?, channel: String?, minimumSystemVersion: String?,
                architectures: [String]) {
        self.signatureValid = signatureValid; self.bundleID = bundleID; self.teamID = teamID; self.build = build; self.channel = channel
        self.minimumSystemVersion = minimumSystemVersion; self.architectures = architectures
    }
}

public enum UpdateBundleCheck {
    /// Why the bundle must not be installed, in words for the dialog; empty when it may.
    public static func problems(_ f: UpdateBundleFacts, manifest m: UpdateManifest, runningBundleID: String, runningTeamID: String?,
                                systemVersion: OperatingSystemVersion) -> [String] {
        var out: [String] = []
        if !f.signatureValid { out.append("Its code signature is invalid or incomplete.") }
        if f.bundleID != runningBundleID { out.append("It's a different app (\(f.bundleID ?? "no bundle ID")).") }
        if runningTeamID == nil || f.teamID != runningTeamID {
            out.append("It's signed by \(f.teamID.map { "team \($0)" } ?? "no team"), not this app's team (\(runningTeamID ?? "none")).")
        }
        if !f.architectures.contains("arm64") { out.append("It isn't built for Apple silicon.") }
        if let need = f.minimumSystemVersion.flatMap(UpdateCatalog.parseVersion) {
            if UpdateCatalog.isNewer(need, than: systemVersion) { out.append("It needs macOS \(f.minimumSystemVersion!) or later.") }
        } else {
            out.append("It doesn't say which macOS it needs.")
        }
        if f.build != m.build { out.append("It says build \(f.build.map(String.init) ?? "?"), but the release is build \(m.build).") }
        if f.channel != m.channel { out.append("It's a \(f.channel ?? "unknown") build, but the release is \(m.channel).") }
        return out
    }
}

public enum FileDigest {
    /// Lowercase hex SHA-256 of a file, read in 1 MB pieces.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
