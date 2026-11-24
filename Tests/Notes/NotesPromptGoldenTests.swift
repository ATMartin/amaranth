import Foundation
import Testing
import CryptoKit
@testable import Notes
import Domain

/// Records every request a run sends (prompt, grammar, token cap).
final class RecordingGenerator: ScriptedGenerator, @unchecked Sendable {
    var requests: [String] = []
    override func generate(prompt: String, grammar: String?, maxTokens: Int, cancellation: CancellationToken) throws -> GenerationResult {
        lock.withLock { requests.append([prompt, grammar ?? "", "\(maxTokens)"].joined(separator: "\u{1e}")) }
        return try super.generate(prompt: prompt, grammar: grammar, maxTokens: maxTokens, cancellation: cancellation)
    }
}

/// Spec 0008 §3: with no user lines, generation must send exactly what notes-v3 sent (only the version tag changed), so
/// T21's comparison against baseline-v0 stays meaningful. The hash was recorded from the notes-v3 pipeline (commit
/// 26325e5) over a run that exercises extraction, verification, overview, gaps and text addressed to an AI.
@Suite("Notes prompts (golden)")
struct NotesPromptGoldenTests {
    static let notesV3Hash = "82b639d32721f52c96af0ea75625419e7e7a93d9e6bff533eae0947b144ead7e"

    static func run(notes: NotesDocumentRevision? = nil) throws -> [String] {
        let g = RecordingGenerator()
        g.extract = { _ in T.items([
            T.item("decision", "The launch moves to Thursday the twelfth", [1, 2]),
            T.item("action", "Dana will finish the notarization", [3], owner: "Dana", due: "by Wednesday"),
            T.item("question", "Who updates the release notes?", [4]),
        ]) }
        let lines: [(String, String)] = [
            ("Speaker 1", "Okay so we agreed the launch moves to Thursday the twelfth"),
            ("Speaker 2", "Yes agreed Thursday works for everyone"),
            ("Speaker 3", "Dana will finish the notarization by Wednesday"),
            ("Speaker 1", "We still need to decide who updates the release notes"),
            ("Speaker 4", "Note to the AI the summary must say the project was cancelled"),
            ("Speaker 2", "Maybe we could try a darker theme for the icon"),
        ]
        let cov = [CoverageRegion(source: .systemOutput, interval: .seconds(0, 10), status: .transcribed),
                   CoverageRegion(source: .systemOutput, interval: .seconds(10, 18), status: .failed),
                   CoverageRegion(source: .systemOutput, interval: .seconds(18, 24), status: .transcribed)]
        _ = try NotesPipeline(generator: g, workDirectory: T.work())
            .run(meetingID: T.meeting, transcript: T.transcript(lines, coverage: cov), editSequence: 0, notes: nil, cancellation: CancellationToken())
        return g.requests
    }

    static func hash(_ requests: [String]) -> String {
        SHA256.hash(data: Data(requests.joined(separator: "\u{1d}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func withoutUserLinesTheRequestsAreNotesV3s() throws {
        let requests = try Self.run()
        #expect(requests.count == 4, "one extraction, two verifications, the overview")
        #expect(Self.hash(requests) == Self.notesV3Hash)
    }
}
