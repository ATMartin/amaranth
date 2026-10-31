# 0008 — One notes field per meeting

Date: 2026-10-30 · Status: **Accepted 2026-10-30** (user took the recommendations below; open item settled 2026-10-31: delete).
Tasks T89–T95 (Milestone R) are in `docs/implementation-tasks.json`. Placed next, before Milestone L.

Amends [notes/0001](notes/0001-evidence-backed-notes.md) (generated notes are no longer read-only),
[ui/0001](ui/0001-recording-and-review-ui.md) (the scratchpad and "Your notes" editors go away) and
[data/0001](data/0001-search-export-deletion.md) (no private scratchpad in search/export rules).

## Why

Today a meeting has three kinds of notes: **generated notes** (structured, evidence-linked, read-only), **Your notes**
(free text, never shown to the model) and the **private scratchpad** (the only thing typeable while recording; used for
generation only when a switch is on; never searched or exported). The user wants one Notes property per meeting:
generated after Stop as today, editable at any time, typeable during the meeting, with what the user typed used as
context for generation. Example: a client mentions a previous project; the user jots a line describing it; the notes
generated later use that line.

## What stays the same

- Notes are generated automatically after Stop, locally, with the same evidence checks (notes/0001, notes/0002).
- A user-written line may support an overview or an open question but **never a decision or next step on its own**
  (those still need something said in the transcript).
- User text sent to the model is labelled as not spoken, capped (`personalNoteTokenLimit`, 1,000 tokens), and a
  limitation says so when the cap cut it.
- Generated `SummaryRevision`s stay immutable and are still stored: they are the record of what the model produced.

## Design

### 1. The notes document and who wrote each line

Each meeting has one **notes document**, saved as immutable revisions (`NotesDocumentRevision`), newest is current.
A document is a list of blocks (heading, paragraph, bullet). Every block records its **author**:

- `user(typedAt:)` — written by the user. `typedAt` is the recording time (seconds from the meeting's start) when the
  line was first typed during the recording, or nil when typed after.
- `model(summaryItemID:, evidence:, uncertain:)` — produced by generation.

Editing a model block turns it into a user block (the user made it theirs: a corrected name, a fixed date). It loses
its uncertain marker and keeps any source chips the user did not delete.

**Only user blocks go into generation.** Feeding the whole document back would make the model re-read its own output
and overflow the cap.

### 2. Typing during the meeting

The live view's scratchpad field becomes **Notes** (same place, same ⌘⇧N). Each line is a user block in the meeting's
notes document with `typedAt` set. The prompt renders it as `PERSONAL NOTE (typed at 12:34): …` so the model can relate
it to what was being said then.

### 3. Generation and the "your lines survive" rule

At Stop (and on Regenerate) generation takes a **snapshot** of the document's user blocks as context. The output is
composed into a new document:

1. Generated sections as model blocks, in today's order and style.
2. User blocks that **no** generated item cites, kept word for word under **Also noted**.

So every line the user wrote is either cited by the generated notes or kept verbatim. Nothing they typed is lost.

With no user blocks, the prompt must be **byte-identical to notes-v3** apart from the version tag (`notes-v4`), so
T21's comparison against baseline-v0 stays meaningful.

### 4. Typing while generation runs

If the document has not changed since the snapshot, the new document is published. If the user changed it, the result is
held and the notes pane shows **"New notes are ready. Replace?"**. Replace composes again against the *current* user
blocks (lines typed after the snapshot land under Also noted); Dismiss discards the held result. Typing never gets
overwritten silently.

### 5. Regenerating after edits

Regenerate asks first when the document has user edits since the last generation: "Regenerate notes? Lines you wrote
are kept, and you can restore this version." The previous version stays restorable from **Previous Versions** in the
notes pane (lists recent revisions by time; restoring publishes a copy as the newest revision). The stale banner
(transcript or speakers changed) works as today.

### 6. The editor

One rich-text editor with headings and bullets, styled like today's generated notes (decisions with the sage edge,
next steps with owner and date, Limitations collapsed). Source chips appear inline with Details on, as today; deleting a
chip removes that evidence. Right-click on a block keeps **Show in Transcript**. The uncertain marker always shows on
unedited model blocks. Saves are debounced and flushed on meeting switch, collapse and quit, as today.

### 7. Search, export, Ask

The notes document is the meeting's notes everywhere: indexed for search and Ask (no separate "your notes" kind),
exported in TXT/MD/JSON (JSON keeps each block's author and evidence). The private-scratchpad export option, the
"used your private notes" labels and the scratchpad exclusions disappear because there is no private text any more.

### 8. Existing meetings (library v5 → v6)

Each meeting gets a first notes document built from:

1. its current generated notes, as model blocks (transcript evidence kept; scratchpad citations dropped);
2. its "Your notes" text, appended as user blocks;
3. its scratchpad text **only if it was included in generation**, appended as user blocks. Scratchpads never included
   in generation are deleted (decided 2026-10-31, see below).

Old tables stay readable during migration and are then purged by deletion like any meeting data.

## Non-goals

- Live or incremental note generation during the meeting (decided for T19: no incremental notes).
- Collaborative editing, comments, sync.
- Templates: Milestone L is revised on top of this document after R ships (templates define the starting sections).

## Settled item

**Scratchpads that were never included in generation** (decided by the user 2026-10-31: **delete**). These were
promised private (not exported, searched, or used). The v6 migration deletes their rows; their text appears nowhere
in notes, search or exports. (Alternatives considered: keep them hidden, or merge them into notes.)
