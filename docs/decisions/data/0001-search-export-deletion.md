# Data 0001: Search, export, retention and deletion (T11)

Date: 2026-10-16 · Task: T11 · Status: Accepted for v0.

## Decision

**Search.** SQLite FTS5 (schema v2, `unicode61 remove_diacritics 2`) over titles, the *current* transcript with text
corrections applied, the current notes, and the latest user notes.
- The private scratchpad is **not** indexed.
- Rows are rewritten in the same transaction as any change to that content: publishing a transcript or summary,
  saving user notes, a text correction, or a title change.
- Rows are purged on deletion.
- User input becomes quoted prefix terms, so FTS syntax cannot be injected.
- Databases created before v2 are backfilled once at launch.

**Export** (`Export` module). TXT, Markdown, and versioned JSON (`amaranth-export` v1), each built from the *selected*
transcript and summary revisions.
- Lines carry a session timestamp (plus wall-clock time when known), the speaker label shown in the app, and the
  source track.
- Unknown and overlapping speakers stay explicit. Audio with no text is listed as a gap.
- Notes disclose when they are stale, uncertain, or influenced by personal notes.
- The private scratchpad is excluded unless explicitly selected.
- JSON contains the contract revisions, with ISO-8601 dates in UTC including fractional seconds. The transcript is the
  *displayed* one: the selected machine revision with the user's text corrections applied. The machine text is kept
  in the app.
- Markdown escapes Markdown and HTML syntax in spoken and generated text, so injected links, images or HTML stay
  inert text.
- Audio is exported only when the user asks: the original lossless CAF segments plus a manifest of session times and
  gaps. Gaps are never filled with silence.

**Retention.** Originals are kept until the user deletes them. Disk use per meeting is shown, split into original
audio and re-creatable derivatives.

**Delete audio only.**
1. The audio stages are cancelled.
2. `Meeting.audio` is set to `.deletedByUser` before anything is removed.
3. Segment rows, the meeting's audio folder, the prepared 16 kHz analysis audio and any other audio file under the
   work folder are removed.
4. Text stage outputs (the transcript and diarization JSON that speaker edits re-reconcile from, and notes
   checkpoints) are kept, so edits keep working (`speakerEditsStillWorkAfterAudioOnlyDeletion`).

Text, notes, edits and search remain. Playback is disabled, and `enqueuePipeline` or any audio stage fails with
`audio.unavailable`.

**Delete meeting.**
1. `JobScheduler.delete` tombstones the meeting first, so no late result can publish.
2. Jobs are cancelled.
3. `purgeMeeting` removes every row with meeting content in one transaction, plus all search rows, the meeting folder
   and the work folder (whose checkpoints contain transcript text).
4. The meeting row is scrubbed to its ID and deletion time.
5. **Tombstone guards:** every store write keyed by meeting (jobs, transcript revisions, diarization, edits, scratchpad,
   user notes, capture records) is a no-op once the meeting is tombstoned, checked inside the write's own
   transaction. A late worker update or a recovery replay can't re-create rows. When a job of a deleted meeting
   finishes, the scheduler removes the work folder again, in case the worker wrote checkpoints after the purge.

**Bytes on disk.**
- `PRAGMA secure_delete=ON` zeroes deleted content.
- The FTS index is optimized after a purge, because FTS5 keeps deleted terms in its segments until a merge. A test
  caught this.
- `wal_checkpoint(TRUNCATE)` leaves no deleted text in the WAL.

## Evidence (`Tests/DataLifecycle`, all passing)

| Acceptance (T11) | Test | Result |
|---|---|---|
| Exports match the selected revisions; no private scratchpad by default | `exportsSelectedRevisionsWithTimestampsSpeakersAndGapsButNoScratchpadByDefault` | Pass. A newer transcript doesn't leak into an export of the selected one; stale notes are labelled; JSON round-trips; the scratchpad appears only when chosen. |
| Audio export only on request, lossless, gaps listed | `audioIsExportedOnlyWhenAskedLosslessWithGapsListed` | Pass (byte-identical copies) |
| Audio-only deletion keeps text readable and searchable and disables playback and retranscription | `audioOnlyDeletionKeepsTextSearchableAndDisablesPlaybackAndRetranscription` (no audio file left anywhere); `speakerEditsStillWorkAfterAudioOnlyDeletion` | Pass |
| Deletion during processing cannot be undone by a late worker result | `completeDeletion…` (`publishTranscript` and `publishSummary` return false after deletion) and `deletionDuringProcessingNeverPublishesLateResults`: zero job rows, no revisions and no work folder after a worker finishes past deletion | Pass |
| Search indexes and caches contain no deleted meeting after relaunch | `completeDeletionLeavesNoContentRowsFilesSearchEntriesOrBytes` | Pass. A unique marker word, the title, user notes and scratchpad text are **absent from the raw bytes** of `amaranth.sqlite` and the WAL; a reopened store finds nothing. |
| Search behaviour | `searchCoversTranscriptNotesTitlesAndUserNotesButNotTheScratchpad` | Pass (prefix search, injection-safe query, title updates, rebuild idempotent) |

## Limits
- Files the user exported elsewhere are outside Amaranth's control. The delete dialog says so.
- APFS snapshots and Time Machine may still hold deleted files; that is outside the app's control and is documented
  for T13.
