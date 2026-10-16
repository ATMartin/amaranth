import Testing
import ProcessingCore
import ASR
import Notes

@Suite("Pipeline versions")
struct PipelineVersionTests {
    /// Job config hashes must change exactly when a stage's producing code changes.
    @Test func configHashesMatchTheirModules() {
        #expect(PipelineVersions.asr == TranscriptionPipeline.pipelineVersion)
        #expect(PipelineVersions.notes == NotesPrompts.version)
    }
}
