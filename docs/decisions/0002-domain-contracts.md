# 0002 — Frozen domain contracts v1

Date: 2026-10-15 · Task: T01 · Status: Accepted · `ContractVersion.current = 1`

All persisted, exported and IPC JSON travels in a `Versioned<T>` envelope. Readers reject newer versions.
Contract changes belong to the integration owner and must update every affected adapter, fixture and test.

## Time
- `SessionTime`: **integer nanoseconds** from the session origin, derived from host time and sample counters, never
  wall clock. Frame→time conversion uses integer math, so four hours at 44.1 kHz is exact.
- `SessionInterval` is half-open `[start, end)`. Decoding rejects inverted intervals.
- `SessionClock` stores the UTC origin, IANA time zone and host-time origin separately, for display.
- `CaptureEpoch`: per source, monotonic index, native `AudioFormat`, session anchor, host time of frame 0,
  device UID and start reason. Frame counters restart in each epoch. Pause, resume, route change, format change
  and wake each start a new epoch. Gaps advance the timeline and are never collapsed.

## Capture and storage
- `SourceKind` is capture origin (`microphone`, `systemOutput`), **not** a person.
- `AudioSegmentRecord` (staged → committed | quarantined) and `CaptureEvent` (gap, pause, overrun,
  sourceFault, sleep, …) carry reason codes and never speech. `CaptureEvent.isMissingAudio` separates missing audio from silence.
- `CaptureState`: idle → preparing → recording ↔ paused → stopping → captured | capturedWithGaps | interrupted.
  `interrupted` → `recording` is allowed only as an explicit resume. Capture state is independent of processing state.
- Protocols: `AudioSource` (frames never cross into SwiftUI or actors) and `SegmentStore` (`commit`, `enumerateCommitted`, `recover`).

## Transcript, speakers and edits
- `TranscriptRevision` is immutable, with `kind: provisional | final` (live text promoted, see 0003) and
  `stage: asr | attributed`. `coverage` marks every interval as transcribed, noSpeech, missingAudio, paused, … so
  unknown coverage is never silently omitted.
- `Word.text` is the original ASR output. Corrections live only in `UserEdit`. `ASRQuality` keeps the engine's raw
  named values, never invented probabilities.
- `SpeakerAssignment`: `unknown | speaker | multiple`. `Speaker` is session-scoped, with an anonymous label and an
  optional user `displayName`. There are no voiceprints.
- `UserEdit`: rename, merge, reassign (to existing, new or unknown), markUncertain and correctText, with a sequence,
  base revision, lineage and conflict state (`needsReview` instead of overwriting).

## Notes
- `SummaryRevision` targets one transcript revision plus an edit sequence and has a stale flag. `SummaryItem.owner` is
  nullable, meaning unknown. `DueDate` keeps the original text and normalizes only when unambiguous.
- `EvidenceRef` is either `transcript(segment, word span)` or `personalNote(scratchpad span)`, as distinct types.
  `validateReferences` rejects unresolved spans and personal-note evidence without opt-in.
- `SummaryInputSnapshot` drops the scratchpad unless `includeInSummary` is set.

## Jobs, models and worker
- `ProcessingStage` DAG: prepare → {transcribe, diarize} → reconcile → notes, plus `live`. Heavy stages are serialized.
- `ProcessingState` adds `suspended` (with a reason) so deliberately paused work is never shown as stuck.
  `JobKey` (input hash + config/model/prompt hash) gives idempotent result slots. Jobs carry a lease, heartbeat and checkpoint.
- `ModelManifest.validatePinning()` rejects `main`/`latest` revisions and files without a sha256.
  `ModelRegistry.resolve` never downloads.
- Pipeline protocols `Transcriber`, `Diarizer`, `Reconciler` and `Summarizer` take a `CancellationToken`.

## Fixtures
`DomainFixtures` provides deterministic meetings: a two-source conversation (with overlap, an unknown ack,
a null owner and a supported owner), a missing source (15 s system fault, notes failed, audio saved), a pause
(new epochs at 45 s, not shifted) and a stale summary (edits after generation). It also provides
`FakeInferenceWorker` with checkpoint resume and fault injection.
