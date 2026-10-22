/// Config hashes for job keys. Each must equal the producing module's own version constant (tests enforce this:
/// `TranscriptionPipeline.pipelineVersion`, `NotesPrompts.version`), so a pipeline change re-runs exactly the
/// affected stages.
public enum PipelineVersions {
    public static let asr = "asr-pipeline-v8"
    public static let diarization = "diar-v1"
    public static let notes = "notes-v2"
}
