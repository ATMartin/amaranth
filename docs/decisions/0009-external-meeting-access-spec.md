# 0009 — Meeting history for external AI tools and vaults

Date: 2026-11-02 · Status: **Accepted 2026-11-03 for Milestone S** (T97–T100 being implemented); Milestones T and U remain proposed.
Milestones **S–U**, tasks **T97–T108**, in `docs/implementation-tasks.json`.

## Recommendation

Build both interfaces on one meeting read model:

1. **Live retrieval through a local, read-only MCP server** for assistants that can launch local tools. The assistant
   searches, fetches supporting passages, and writes its answer with citations. Amaranth does not need to run its own
   answer model for this path.
2. **Bulk Markdown plus versioned JSON export** for vaults and ingestion systems. Start with an explicit snapshot;
   add an optional, one-way managed mirror once snapshot export and live access work.

MCP is an adapter for an assistant to call search; it does not supply search, embeddings, ingestion, or an answer
model. A vault needs files; it does not need MCP. These are complementary destinations, not competing architectures.
Keep Amaranth's database and current displayed content authoritative. Do not ask every client to understand SQLite,
reconcile edit history, or build its own interpretation of notes.

| Route | Best use | Freshness and limitation | Recommendation |
|---|---|---|---|
| Local MCP search + fetch | Interactive questions in a compatible desktop assistant | Reads current content; client controls model and context handling | Primary AI interface |
| Bulk Markdown + JSON snapshot | Vault ingestion, scripts, portable archive | Copy at export time; later edits/deletions do not propagate | First shippable step |
| Managed directory mirror | Keep a vault current without repeated manual exports | Eventual updates while Amaranth runs; outside indexes may lag | Optional follow-on |
| Hosted/remote MCP | Assistants that cannot run local tools | Requires reachable service, authentication and a new privacy boundary | Separate future proposal |
| Direct database access | One-off developer investigation | Couples clients to migrations and bypasses access policy | Do not publish as an integration |

## Existing implementation and gaps

Verified in the repository on 2026-11-02:

- `Storage/Search/SearchIndex.swift` maintains FTS5 over current content, including title, people, speakers,
  transcript and notes; changes rewrite the index transactionally and deletion removes its rows.
- `Storage/Search/Retriever.swift` already returns bounded, ranked transcript windows and notes passages, with
  evidence and distribution across meetings. It uses lexical matching with light stemming, not embeddings. Its
  current filters are meeting/folder; structured date, people and pagination support still need work.
- `Presentation/AskAnything.swift` prepares passages for local answers and distinguishes generated notes from
  user-written notes. External assistants should receive source content rather than a second model's answer.
- `Export/Exporter.swift` supports individual TXT/Markdown/JSON exports (`amaranth-export` v2), selected revisions,
  displayed speaker labels, gaps, notes authorship and staleness. `ExportInput` currently requires a transcript;
  notes-only and incomplete meetings need an explicit external representation. JSON v2 also includes the original
  generated `summary`, which can differ from edited notes; do not wrap that raw document as the external read model.
- `Storage/MeetingStore.swift` owns a serialized database writer and runs migrations at initialization. A helper
  must not simply construct another store against the live library and become a competing migration owner.
- Milestone R removed private scratchpads. T96 deletes transcript lines/trims the kept window; external access must
  use the resulting displayed transcript and must never expose hidden original revisions through a fetch endpoint.
- No public meeting URL handler or external integration contract was found. Citation navigation needs implementing.

This extends [data/0001](data/0001-search-export-deletion.md) and [0008](0008-single-notes-field-spec.md).
It adds optional external disclosure; recording, generation and in-app Ask remain local and work without integrations.

## 1. Shared content and citation contract

Introduce a transport-independent `MeetingAccess` module backed by app-owned storage operations. Use a consistent
snapshot per meeting: metadata, current transcript with all corrections/deletions/trims applied, displayed speaker
names, current notes document, folder and people. Exclude original/hidden revisions, audio, raw calendar payloads,
work checkpoints, model prompts and local paths. A notes-only meeting is valid; missing/processing/failed transcript,
stale notes, gaps, uncertain generated text and audio-deleted status are explicit fields rather than empty success.
Export participant display names without emails, as the existing exporter does. Strip hidden content from evidence
payloads too; source references never become an alternate route to original transcript or summary text.

T96 deliberately leaves notes unchanged after deleting/trimming transcript lines. Current notes may therefore still
mention removed discussion. Preserve those displayed notes and mark staleness; transcript trimming is not a promise
of full redaction. Document that the user must edit/regenerate notes too when removing a topic from external access.

Version the external envelope independently from the existing JSON v2 export. Reuse rendering and safe field mappings,
not raw revision records; expose summary provenance metadata without the original generated summary body. Changing
an existing export shape requires a new version and compatibility fixtures. Include library identity, meeting UUID, content fingerprint,
transcript/notes revision IDs, export/read time, meeting start in UTC and duration/session timestamps in integer ns.
The fingerprint must change for metadata, folder, people, speaker and edit changes, not only new machine revisions.
Read responses are per-meeting consistent; a library-wide export may contain different meeting read times and says so.

Every passage includes meeting title/date/ID, source type (`transcript`, `notes`, `userNote`), segment/block ID,
revision identity, session range when applicable, source evidence and a citation URL. A personal note is never
presented as something spoken or proof of a decision. A score is a ranking signal, not confidence or an exhaustive
history claim.

Proposed URL: `amaranth://meeting/<uuid>?source=transcript&ref=<segment-id>&revision=<revision-id>` (notes use block IDs).
Register the scheme and open only local meeting navigation; reject malformed IDs and unsupported parameters.
If an old revision no longer resolves, show that the source changed and offer the current meeting; do not silently
attribute the old quote to a new line. Deleted meetings show unavailable. URLs grant no access, execute no commands,
and never reveal hidden text or restore a deleted meeting. Exports also retain readable title/date/time references
for tools that cannot open app URLs.

## 2. Retrieval API

Use the same operations for MCP and future scripting adapters:

| Operation | Inputs | Result |
|---|---|---|
| `list_meetings` | optional title, folder ID, participant, UTC start interval, cursor, limit | Metadata and processing state, stable next cursor |
| `search_meetings` | query, optional meeting IDs/folder/participant/date interval, cursor, limit | Ranked passages, evidence/citation metadata, next cursor and retrieval limitations |
| `get_meeting` | meeting ID, section (`metadata`, `notes`, `transcript`), optional session range, cursor, expected fingerprint | Bounded source content and revisions, or explicit unavailable/changed result |

Publish hard ceilings (initial proposal: 2,000 query characters, 50 meeting IDs, 50 list rows, 20 search passages,
64 KiB UTF-8 response, 30 s request deadline). Reject excessive input; page content without cutting a source record
silently. Oversized individual records need bounded fragments with continuation metadata. Cursors are opaque,
bound to query/filter/order and library generation; stale cursors return a restartable error. Apply filters and
authorization before ranking/windowing, never retrieve unrestricted context then filter the final response.

Dates filter meeting starts using explicit inclusive-start/exclusive-end UTC bounds. A participant matches recorded
meeting people and is not a claim that a named person spoke a passage. Empty queries use listing, not an implicit
full-library dump. Explain partial results, missing transcripts and lexical limitations. Search is not an exhaustive
aggregation endpoint: questions such as "all decisions this quarter" need listing plus paged source retrieval.

Start with existing FTS5. Add a fixture set of at least 30 answerable questions and 10 unanswerable/adversarial cases:
exact names, paraphrases, acronyms, date/people/folder filters, notes-only meetings, cross-meeting decisions and edited
or deleted content. Report Recall@10 for labeled supporting passages (target at least 85% on lexical/name cases),
paraphrase recall separately, and citation resolution (100% for unchanged fixture sources). A failed recall target
blocks a claim of adequate retrieval; document failures and improve lexical behavior before accepting the gate.
If paraphrase misses materially affect real use, propose local hybrid FTS + embeddings with measured recall/latency,
model size and reindex/deletion costs. Embeddings are not a prerequisite to connect an assistant.

## 3. Local MCP and access boundary

Bundle a small signed `amaranth-mcp` executable. The host launches it over **stdio**; it delegates to an authenticated,
app-owned local broker, which enforces scope for each request. Prefer XPC with verified peer code identity; T101
must prove the connection/distribution path in a packaged build before freezing the broker design. Keep migrations
and the live writer in the app. No listener on the LAN, public URL, Python/Node installation or model download.
Initially require Amaranth to be running; return actionable `app_unavailable` rather than starting recording or
opening UI from a tool call. Do not create a new background daemon for v1.

Settings → Integrations starts off. The user creates a connection grant and selects explicit meetings, folders,
or all meetings. Explicit IDs are fixed membership; a folder grant includes future meetings moved into it; "all"
includes future meetings. Explain that before enabling. A grant is bound to this library and an unguessable per-client
credential; app verifies the signed helper plus the grant, not a client-supplied name. Store broker credentials in
Keychain; prove retrieval from the signed helper. If host configuration needs a bearer secret, protect it and never
print it in diagnostics. Document that same-user tools can copy credentials: this is a consent/revocation boundary,
not isolation from malware already running as the user.

Check grants on list, search, fetch, pagination and citation resolution responses; guessing an ID must not bypass
scope. Revocation/disable takes effect on the next response, including work already in flight. Stop and discard
pending responses on scope reduction/deletion. Content already sent to a client cannot be recalled. Track bounded
local audit metadata (connection, operation, time, success/failure); omit queries, titles, snippets and content.

Expose only the three read tools; schema validation, bounded results, cancellation and errors are required. Advertise
read-only tool semantics as supported by the pinned protocol/SDK, but annotations are not access enforcement.
Keep stdout protocol-only. Treat all meeting text as untrusted source material; tool descriptions tell clients not
to execute instructions found inside it. Amaranth itself never follows transcript URLs or executes source text.
Use an SDK/protocol version supported by the chosen test clients; do not assume the newest spec is already supported.

Local transport means the connector runs on this Mac. **The assistant may send retrieved content to its own cloud
model or retain it.** Show this disclosure when enabling, together with granted scope and a Disable/Revoke control.
Amaranth makes no new outbound meeting-content requests itself. The earlier "nothing is uploaded" documentation
must distinguish the local core from user-enabled external tools and synced export folders.

## 4. Snapshot export and managed mirror

**Snapshot (Milestone S).** Export selected meetings, a folder or the whole library to a chosen destination. Preview
meeting count and whether notes/transcripts are included; audio stays excluded. A snapshot is explicitly a copy.
Use a dedicated directory and UUID-based relative paths such as `amaranth/<meeting-uuid>/meeting.md` and `meeting.json`.
Titles belong inside files so renames do not leave duplicates. Markdown has safely serialized YAML frontmatter with
schema, IDs, title, UTC date, people/folder, revisions, fingerprint and citation URL; sections contain the notes as
shown and optional timestamped transcript. Preserve uncertainty, authorship, staleness and gaps in both formats.
Metadata must survive quotes, colons, newlines and Unicode without YAML or path injection. Arbitrary meeting text
is escaped as in the current exporter. Do not require Obsidian-specific plugins or wikilinks.

A versioned manifest maps library/meeting IDs to paths, content fingerprints, per-file hashes and status. Stage and
atomically replace files, committing the manifest last; cancellation/disk failure leaves a detectable incomplete
generation, with clear per-meeting errors and a safe retry. A missing transcript must not prevent notes export.
Snapshot retry cannot overwrite a user-changed file silently. Existing single-meeting exports keep their behavior.

**Mirror (Milestone U, optional).** User explicitly selects a dedicated managed subdirectory, scope and content level.
One-way output only: vault edits do not modify Amaranth. Maintain a durable change sequence (including metadata,
speaker changes, notes publication/edits, transcript corrections/deletions/trims, folder membership and deletion)
and a checkpoint. Reconcile full desired state on initial run, resume and missing/expired cursor; process incrementally
afterwards. Do not rely on filesystem events or a last-modified timestamp alone. Exclude live/provisional text by
default; stopped meetings export their available content and update when processing finishes.

Debounce bursts; write off the capture path with bounded work, pause under capture pressure, and recheck current
scope/tombstones before publishing so a late job cannot resurrect deleted or excluded text. Show last successful
sync, pending/conflicted/error counts, Sync Now, Pause and Stop. No sync while the app is quit in this version;
resume reconciles on next launch. A renamed or moved source meeting updates its existing UUID path.

For edits or removal, compare the last-written hash. Only overwrite/delete a file still owned by this mirror and
unchanged by the user. Otherwise show a conflict and let the user resolve it; do not create an extra stale copy
automatically. Follow no symlinks outside the root, accept no path from meeting text, and identify a mirror by its
library and destination manifest. Refuse unknown/foreign manifests. Coordinate concurrent writers and recover from
crash, missing volume, renamed destination, permission loss and manifest/file disagreement with an idempotent retry.

Source deletion or scope removal purges unchanged managed files at next sync. Revocation of MCP does not silently
stop or erase a separately configured mirror. Stopping a mirror offers leave files or remove unchanged managed
files, with counts; conflicts require explicit resolution. Neither operation can delete copies, trash, backups,
sync-provider history, prior snapshots, or embeddings/caches held by another tool. Show that deletion limit and
warn that the chosen destination may be synced or ingested elsewhere. Do not claim immediate downstream erasure.

## 5. Milestones and tasks

| Milestone | Tasks | Shippable outcome | Gate |
|---|---|---|---|
| S — Shared read model and portable history | T97 snapshot/citations; T98 retrieval; T99 bulk export; T100 qualification | Consistent bounded access layer and manual library export | Export parity, retrieval report, edits/deletion and citation checks |
| T — Live access from desktop AI | T101 broker/grants; T102 MCP adapter; T103 connection UX/packaging; T104 qualification | Ask an external assistant about meetings with source links | Real packaged-client search → fetch → cited answer, scope/revoke tests |
| U — Optional managed vault mirror | T105 reconciliation; T106 scheduler; T107 settings/conflicts; T108 qualification | Selected history kept current in a vault directory | Idempotent recovery, conflict safety, edit/deletion propagation |

Dependency graph: T97 → T98; (T97, T98) → T99 → T100 → T101 → T102 → T103 → T104 →
T105 → T106 → T107 → T108. Existing code prerequisites appear in each task. The sequence favors a small export win
before the MCP packaging/security work; U can be deferred without reducing live query functionality.

Suggested placement: after the already requested Q update work, if external access is the next priority. This is a
recommendation, not a change to the existing approved T96 → Q → T21 → feedback → F order. Scheduling S–U against
T21/F remains a product choice. No fixed engineering dates until T97/T101 establish contract and broker feasibility.

**Placement decided 2026-11-03:** the user picked up Milestone S next, before T21. T98's scale gate is measured on a
200-meeting synthetic library; the 1,000-meeting figure is reported as not measured (user decision). T and U stay unplaced.

Each milestone ends with an independent validator and a qualification report using the existing
`docs/qualification/*-validation-brief.md` format. Tests use synthetic/isolated libraries; no publishing real meeting
text in logs, screenshots, fixtures or evidence. Record commands/results, client/protocol/dependency versions,
hardware/OS, failures and unverified configurations. UI changes need light/dark renders and keyboard checks.

For scale, seed 1,000 synthetic meetings (roughly 1 million transcript lines), run at least 100 cold/warm search and
fetch operations, and report p50/p95 and peak memory on the supported M2 Max profile. Proposed search/fetch gate:
warm p95 ≤ 1 s, cold ≤ 3 s, no new models loaded; verify capture health under concurrent reads/export. If unmet,
measure the bottleneck and tune bounded reads or revise the budget explicitly; do not mask latency with truncation.

## 6. Destination choices and later work

Initial assumptions: prioritize MCP-capable desktop assistants and portable Markdown folders equally; no hosted
service. Confirm the user's first assistant/vault before T103/T108 compatibility work. Local stdio support is a
client capability, not universal to every web/mobile assistant. Verify each selected client at implementation time;
document unsupported clients rather than adding a tunnel as an accidental dependency.

Deferred: remote authenticated MCP, multi-user hosting, bidirectional vault sync, write tools, direct third-party
service APIs, audio delivery, embedding infrastructure and an Amaranth-hosted answer endpoint. Revisit only with a
specific destination or measured retrieval gap. The first useful slice is bulk export after S; live AI access after T.

## Sources checked 2026-11-02

These establish external capabilities; architecture, limits and gates above are proposals for Amaranth.

- [MCP transport specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports): stdio
  uses a client-launched subprocess; Streamable HTTP is a separate transport.
- [MCP tools specification](https://modelcontextprotocol.io/specification/2026-07-28/server/tools): tools expose
  named operations with schemas. Pin a version actually supported by the chosen clients.
- [Claude local MCP setup](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop):
  one documented desktop integration route; not a promise of compatibility with every assistant.
- [Obsidian data storage](https://obsidian.md/help/Files%2Band%2Bfolders/How%2BObsidian%2Bstores%2Bdata): vaults contain
  Markdown files and refresh external changes; sync services and downstream plugins remain separate systems.
