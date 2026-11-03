import Testing
@testable import Presentation

@Suite("Build info (T70)")
struct BuildInfoTests {
    @Test func readsTheStampedKeys() {
        let b = BuildInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "124", "AmaranthCommit": "a1b2c3d",
                                           "AmaranthDirty": true, "AmaranthBuildDate": "2026-11-02T10:00:00Z", "AmaranthChannel": "release"])
        #expect(b == BuildInfo(version: "0.1.0", build: 124, commit: "a1b2c3d", dirty: true, date: "2026-11-02T10:00:00Z", channel: .release))
        #expect(b.label == "0.1.0 (124)" && b.commitLabel == "a1b2c3d, modified")
    }

    @Test func anUnstampedBuildIsBuildZero() {
        let b = BuildInfo(infoDictionary: ["CFBundleVersion": "1.2"])
        #expect(b.build == 0 && b.commit == "unknown" && b.channel == .debug && b.label == "0 (0) Debug")
    }
}
