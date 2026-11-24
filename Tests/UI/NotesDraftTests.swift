import Foundation
import Testing
import Domain
import Presentation
import Storage

/// T91: editing the notes document in the pane (spec 0008 §1, §5, §6).
@Suite("Notes draft")
struct NotesDraftTests {
    let m = MeetingID("m")
    let spoken = EvidenceRef.transcript(.init(revisionID: RevisionID("tr"), segmentID: .init("s"), firstWord: .init("a"), lastWord: .init("b")))

    /// Fixed IDs throughout: computed again on each use.
    var generated: NotesDocumentRevision {
        NotesDocumentRevision(id: RevisionID("g"), meetingID: m, createdAt: Date(timeIntervalSince1970: 0), basedOnSummaryRevisionID: RevisionID("sum"), origin: .generated, blocks: [
            NoteBlock(id: NoteBlockID("h1"), kind: .heading, text: "Decisions", section: .decisions, author: .model(summaryItemID: nil, uncertain: false)),
            NoteBlock(id: NoteBlockID("d1"), kind: .paragraph, text: "Ship Thursdy", author: .model(summaryItemID: SummaryItemID("d1"), uncertain: true), evidence: [spoken]),
            NoteBlock(id: NoteBlockID("h2"), kind: .heading, text: "Next steps", section: .nextSteps, author: .model(summaryItemID: nil, uncertain: false)),
            NoteBlock(id: NoteBlockID("a1"), kind: .bullet, text: "Send the plan", detail: "No owner stated  ·  no date stated",
                      author: .model(summaryItemID: SummaryItemID("a1"), uncertain: false), evidence: [spoken]),
        ])
    }

    /// No "Write a note…" line after the notes (2026-10-31 feedback); notes with no lines get one line to type into.
    @Test func aFreshDraftIsTheNotesAndIsClean() {
        let d = NotesDraft(meetingID: m, base: generated)
        #expect(d.blocks == generated.blocks)
        #expect(!d.isDirty && d.content == generated.blocks)
        #expect(NotesDraft(meetingID: m, base: nil).blocks.count == 1)
        let onlyLimitations = NotesDocumentRevision(meetingID: m, createdAt: Date(), origin: .generated, blocks: [
            NoteBlock(kind: .heading, text: "Limitations", section: .limitations, author: .model(summaryItemID: nil, uncertain: false)),
            NoteBlock(kind: .bullet, text: "Short recording", author: .model(summaryItemID: SummaryItemID("l1"), uncertain: false))])
        let l = NotesDraft(meetingID: m, base: onlyLimitations)
        #expect(l.blocks.count == 3 && l.blocks.last?.isUser == true && NotesEditing.layout(l.blocks).notes.map(\.id) == [l.blocks[2].id],
                "the line to type into is in the notes, not under Limitations")
        #expect(!l.isDirty)
    }

    @Test func editingAModelLineMakesItTheUsersAndSavesAsANewRevision() {
        var d = NotesDraft(meetingID: m, base: generated)
        d.setText(NoteBlockID("d1"), "Ship Thursday")
        let b = d.block(NoteBlockID("d1"))!
        #expect(b.isUser && !b.isUncertain && b.evidence == [spoken])
        d.setDetail(NoteBlockID("a1"), "Dana  ·  Friday")
        #expect(d.block(NoteBlockID("a1"))?.isUser == true && d.block(NoteBlockID("a1"))?.detail == "Dana  ·  Friday")
        #expect(d.isDirty)
        let rev = d.revision(at: Date(timeIntervalSince1970: 9))
        #expect(rev.id != generated.id && rev.origin == .edited && rev.basedOnSummaryRevisionID == RevisionID("sum"))
        #expect(rev.blocks.count == 4)
        #expect(NotesEditing.regenerateNeedsConfirmation(rev) && !NotesEditing.regenerateNeedsConfirmation(generated))
        d.didSave(rev)
        #expect(!d.isDirty && d.base?.id == rev.id)
    }

    @Test func typingLinesShortcutsAndRemoving() {
        var d = NotesDraft(meetingID: m, base: generated)
        let end = d.lineAtEnd()
        #expect(d.blocks.last?.id == end && d.block(end)?.text == "", "clicking below the notes adds a line at their end")
        #expect(d.lineAtEnd() == end, "and reuses it while it is empty")
        d.setText(end, "# Client background")
        #expect(d.block(end)?.kind == .heading && d.block(end)?.text == "Client background")
        let next = d.insertLine(after: end)
        d.setText(next, "- Lyon rollout")
        #expect(d.block(next)?.kind == .bullet && d.block(next)?.text == "Lyon rollout")
        let after = d.insertLine(after: next)
        #expect(d.block(after)?.kind == .bullet, "Return after a bullet starts a bullet")
        #expect(d.insertLine(after: after) == after && d.block(after)?.kind == .paragraph, "Return on an empty bullet ends the list")
        #expect(d.insertLine(after: d.blocks.last!.id) == d.blocks.last!.id, "Return on the empty last line stays there")
        #expect(d.remove(after) == next, "the cursor goes to the line before")
        #expect(d.remove(d.blocks[0].id) == nil && d.blocks[0].section == .decisions, "generated headings stay")
        d.removeEvidence(spoken, from: NoteBlockID("a1"))
        #expect(d.block(NoteBlockID("a1"))?.evidence.isEmpty == true && d.block(NoteBlockID("a1"))?.isUser == true)
        #expect(d.revision().userBlocks.map(\.text) == ["Send the plan", "Client background", "Lyon rollout"])
    }

    @Test func sectionsCountsAndRestoring() {
        let g = generated
        let sections = NotesEditing.sections(g.blocks)
        #expect(sections[NoteBlockID("d1")] == .decisions && sections[NoteBlockID("a1")] == .nextSteps)
        #expect(NotesEditing.itemCount(after: g.blocks[0].id, in: g.blocks) == 1)
        let r = NotesEditing.restoring(g, currentSummaryID: RevisionID("newer"), at: Date(timeIntervalSince1970: 5))
        #expect(r.id != g.id && r.blocks == g.blocks && r.origin == .restored && r.basedOnSummaryRevisionID == RevisionID("newer"),
                "a restored version is never shown as pending against the current notes")
        #expect(NotesEditing.versionLabel(g, now: Date(timeIntervalSince1970: 3600)).hasSuffix("· Generated"))
    }

    /// T91 acceptance: an edit persists across relaunch, and a restored version is exactly the earlier one.
    @Test func editsPersistAcrossRelaunchAndRestoreExactly() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amr-draft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        try store.upsertMeeting(Meeting(id: m, title: "T", createdAt: Date(), captureState: .captured))
        #expect(try store.saveNotesDocument(generated))
        var d = NotesDraft(meetingID: m, base: try store.currentNotesDocument(m))
        d.setText(NoteBlockID("d1"), "Ship Thursday")
        d.setText(d.blocks.last!.id, "my own line")
        #expect(try store.saveNotesDocument(d.revision()))
        let reopened = try MeetingStore(root: root)
        let current = try #require(try reopened.currentNotesDocument(m))
        #expect(current.blocks == d.content)
        let earlier = try #require(try reopened.notesDocumentRevisions(m).last)
        #expect(try reopened.saveNotesDocument(NotesEditing.restoring(earlier, currentSummaryID: nil)))
        #expect(try reopened.currentNotesDocument(m)?.blocks == generated.blocks)
        #expect(try reopened.notesDocumentRevisions(m).count == 3, "nothing is lost: the edited version stays too")
    }

    /// The pane's layout: the pinned header replaces the generated overview heading, Limitations is a footnote (lines the
    /// user wrote after it show with the notes), and the button says Generate until the meeting has generated notes.
    @Test func layoutAndGenerateTitle() {
        let model = NoteAuthor.model(summaryItemID: nil, uncertain: false)
        let blocks = [NoteBlock(id: NoteBlockID("o"), kind: .heading, text: "Meeting notes", section: .overview, author: model),
                      NoteBlock(id: NoteBlockID("o1"), kind: .paragraph, text: "Summary", author: .model(summaryItemID: SummaryItemID("o1"), uncertain: false)),
                      NoteBlock(id: NoteBlockID("l"), kind: .heading, text: "Limitations", section: .limitations, author: model),
                      NoteBlock(id: NoteBlockID("l1"), kind: .bullet, text: "Short", author: .model(summaryItemID: SummaryItemID("l1"), uncertain: false)),
                      NoteBlock(id: NoteBlockID("u"), kind: .paragraph, text: "Mine", author: .user(typedAt: nil))]
        let layout = NotesEditing.layout(blocks)
        #expect(layout.notes.map(\.id) == [NoteBlockID("o1"), NoteBlockID("u")])
        #expect(layout.limitations.map(\.id) == [NoteBlockID("l"), NoteBlockID("l1")])
        let empty = NotesDraft(meetingID: m, base: nil)
        #expect(NotesEditing.isEmpty(NotesEditing.layout(empty.blocks).notes))
        #expect(NotesEditing.generateTitle(.none) == "Generate")
        #expect(NotesEditing.generateTitle(.unavailable("x")) == "Generate")
        #expect(NotesEditing.generateTitle(.ready(stale: true, regenerationError: nil)) == "Regenerate")
    }
}
