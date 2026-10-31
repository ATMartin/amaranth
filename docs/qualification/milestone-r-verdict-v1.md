# Milestone R validator verdict

**PASS WITH FIXES**

Evidence: read all six commits and the spec; reran the golden prompt test against the real notes-v3 code (26325e5 checked out
into the scratchpad, test adapted to the old signature): PASSED, so the pinned hash really is notes-v3's. Wrote and ran a scratch
test on a copy of HEAD that reproduced must-fix 1. Viewed png94 renders (light/dark edited, pending-replace, details, live-notes-open):
layout and dark/light parity fine. Did not re-run ui-render or the library-copy migration (the sandbox denied it); relied on the
supplied counts (v5 -> v6, 5 meetings, 5 documents, 0 mismatches). The one ASR flake is unrelated to R (ASR untouched; 3/3 alone).

## Must-fix
1. **Duplicate block IDs after Regenerate when the user edited a model line.** Domain/Summary/NotesDocument.swift:166 names a model
   block `NoteBlockID(item.id.rawValue)`, and the pipeline's item IDs are deterministic (Notes/Pipeline/NotesPipeline.swift:277
   "decision-<line>-<n>", :406 "overview-<n>", :285 "limitation-<n>"). Editing a model block keeps its ID but makes it a user
   block (NotesDocument.swift editing(...)), so the next compose (NotesDocument.swift:~128-135, kept user blocks appended under Also
   noted) emits the new model block and the user's edited copy with the SAME ID. Reproduced: compose, edit "overview-0", compose
   again -> IDs ["...", "overview-0", "...", "overview-0"]. Consequences: ForEach over duplicate IDs in
   App/Notes/NotesPane.swift:~150 (undefined behaviour), NotesDraft.setText/remove/insertLine/setDetail/removeEvidence use
   `firstIndex(where: id)` (Presentation/NotesEditing.swift:36,48,53,64,72), so typing in the Also-noted copy edits the model copy
   (or deletes the wrong one); `NotesEditing.sections` dictionary collision (:99); search refs collide and Retriever labels a model
   line "your note" (Storage/Search/Retriever.swift userLines set). This is the headline flow (edit, then Regenerate, acceptance of T91).
   Fix: give a block a fresh ID when it becomes user-authored (editing(...)) or have compose re-ID kept user blocks that collide
   with a model block, plus a test that every composed document has unique IDs (add to the property test at NotesDocumentTests).

## Should-fix
1. **Unordered async saves can write an older revision last.** App/Library/LibraryModel.swift:406 `perform` uses Task.detached;
   LibraryModel.swift:405 the flush path is synchronous. A debounced save still waiting in its detached task when the user switches
   meeting or leaves the pane (flush, NotesPane.swift:~72) can insert after the synchronous save, making older text the newest
   revision (current rowid DESC, NotesDocumentRecords.swift currentNotesDocument). Narrow window but silent loss of the visible
   state. Serialize note saves (one serial queue / actor) or make the non-immediate path also drop superseded revisions.
   Related: the optimistic `didSave(rev)` (NotesPane.swift:~60) hides a failed async save (`self.error` only).
2. **A user line cited by a generated item disappears from the document** (NotesComposer.compose cited filter, NotesDocument.swift
   ~126-133). Per spec, but the next Regenerate no longer sees it as a user line, so context the user typed is lost to later
   generations unless the model happens to keep it; deleting that model block deletes the thought entirely. Consider keeping
   cited user lines (or their text in the block's evidence) so regeneration input is stable. Spec-consistent, so a judgement call
   for the user.
3. Stale wording: Notes/Pipeline/NotesPipeline.swift:96 "Only the first part of your included personal notes fit..." (nothing is
   "included" any more; add that the rest is kept under Also noted); docs/decisions/notes/0002-faster-notes.md:169 still says
   staleness uses the scratchpad; docs/decisions/0002-domain-contracts.md:39,41 and ui/0004:68 mention the old stores without an
   amendment note (T94 only amended 0001s).
4. Held result and exports: a held summary becomes `detail.summary` while the shown document is based on the older one, so export
   disclosure (Export/Exporter.swift notesDisclosures) and JSON `summary` describe notes the user is not looking at. Use the
   document's `basedOnSummaryRevisionID` summary for the disclosure.
5. Editor polish: Return on an empty bullet adds another bullet instead of ending the list; Return on a non-last line inserts an
   empty line before the trailing blank (NotesEditing.insertLine, harmless, not saved); Delete moves focus onto a hidden
   (collapsed Limitations) block (NotesPane remove focus); a generated heading can be left with "0 items". Markdown export
   `esc` (Exporter.swift:204) does not escape leading "+", "1." or "---", so typed text can turn into a list/rule.
6. RecordingNotes saves with `try?` and still marks them saved (App/Recorder/RecorderModel.swift saveNotes), so a failed write
   is not retried until the text changes again. Crash loses up to 10 s of typing (documented).
7. Migration judgement: a scratchpad whose latest revision has the switch ON is kept as "used" even if the current notes were
   made before it (V5NotesMigration.swift ~37). Acceptable reading of "included", worth saying in the release note. Older
   "Your notes" revisions beyond the latest stay in manual_notes_revisions until the meeting is deleted (not visible anywhere).

## Judgements on the listed deviations
- SwiftUI line-per-block editor: meets spec 6 in function (headings, bullets, chips, authorship, show-in-transcript, Delete/Return)
  but is not one continuous rich-text selection (no multi-line selection or paste of formatted text); acceptable, call it out to
  the user.
- Prompt line format, derived "held", evidence vs ownerEvidence, legacy decode fields: all acceptable; the T94 grep acceptance is met
  in code (only migration, deletion, schema, legacy decode fields and tests). Docs have the leftovers in should-fix 3.
- Golden test is sound (verified); the "user line alone cannot make a decision" guard is at NotesPipeline.swift:152 and tested.
- v6 migration: same transaction, secure_delete on, WAL checkpoint and index rebuild for previousVersion 1..<6, deletion purges
  notes_document_revisions; never-included scratchpad removed from rows, search and bytes (tested).

## Recommended hands-on checks (checklist 78-84, plus)
1. Record, type three lines in live Notes (one edited, one deleted), Stop; confirm lines appear after generation (cited or under
   Also noted) with times in the prompt.
2. Edit a generated line (e.g. a decision), type a new line, Regenerate: confirm the dialog, that both appear once each, and that
   editing/deleting the Also-noted copy does not change the generated line (must-fix 1).
3. Type in the pane while notes generate: banner "New notes are ready. Replace?"; Replace keeps lines typed after the snapshot; Dismiss.
4. Previous Versions restores exactly; quit within a second of typing and relaunch: text present; switch meetings quickly while typing.
5. Return/Delete behaviour in bullets and an empty line; "# " and "- " shortcuts; collapsed Limitations; VoiceOver on a line.
6. Export MD/TXT/JSON of a meeting with typed text containing # - * _ [ ]; open the Markdown; confirm no scratchpad text anywhere.
7. Ask and search for a typed phrase: result labelled "your note"; back up and open the migrated real library after installing.
