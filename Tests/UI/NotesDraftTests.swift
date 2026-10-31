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

    @Test func aFreshDraftHasATrailingLineAndIsClean() {
        let d = NotesDraft(meetingID: m, base: generated)
        #expect(d.blocks.count == 5 && d.blocks.last?.isUser == true && d.blocks.last?.text == "")
        #expect(!d.isDirty && d.content == generated.blocks)
        #expect(NotesDraft(meetingID: m, base: nil).blocks.count == 1)
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
        #expect(rev.blocks.count == 4, "the empty trailing line is never saved")
        #expect(NotesEditing.regenerateNeedsConfirmation(rev) && !NotesEditing.regenerateNeedsConfirmation(generated))
        d.didSave(rev)
        #expect(!d.isDirty && d.base?.id == rev.id)
    }

    @Test func typingLinesShortcutsAndRemoving() {
        var d = NotesDraft(meetingID: m, base: generated)
        let trailing = d.blocks.last!.id
        d.setText(trailing, "# Client background")
        #expect(d.block(trailing)?.kind == .heading && d.block(trailing)?.text == "Client background")
        #expect(d.blocks.last?.text == "", "a new trailing line appears")
        let next = d.blocks.last!.id
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

    /// No notes: the pane shows its own "Meeting notes" heading and an invitation; the button says Generate until the
    /// meeting has generated notes.
    @Test func emptyNotesHeadingAndGenerateTitle() {
        let empty = NotesDraft(meetingID: m, base: nil)
        #expect(NotesEditing.needsHeader(empty.blocks) && NotesEditing.isEmpty(empty.blocks))
        let typed = NotesComposer.userBlocks(fromText: "Ask Dana")
        #expect(NotesEditing.needsHeader(typed) && !NotesEditing.isEmpty(typed))
        let generated = [NoteBlock(kind: .heading, text: NoteSection.overview.title, section: .overview, author: .model(summaryItemID: nil, uncertain: false))]
        #expect(!NotesEditing.needsHeader(generated))
        #expect(NotesEditing.generateTitle(.none) == "Generate")
        #expect(NotesEditing.generateTitle(.unavailable("x")) == "Generate")
        #expect(NotesEditing.generateTitle(.ready(stale: true, regenerationError: nil)) == "Regenerate")
    }
}
