import Foundation
import Testing
import Domain

/// Spec 0008 §1: the notes document, who wrote each line, and the composer's "your lines survive" rule.
@Suite("Notes document")
struct NotesDocumentTests {
    let m = MeetingID("m")
    let spoken = EvidenceRef.transcript(.init(revisionID: RevisionID("tr"), segmentID: .init("s"), firstWord: .init("a"), lastWord: .init("b")))

    func summary(_ content: SummaryContent) -> SummaryRevision {
        SummaryRevision(meetingID: m, transcriptRevisionID: RevisionID("tr"), editSequence: 0, createdAt: Date(timeIntervalSince1970: 0),
                        producer: ProducerInfo(component: "t", configHash: "t"), promptVersion: "notes-v4", content: content,
                        validation: SummaryValidationReport(status: .valid))
    }

    @Test func roundTripsEveryAuthorAndEvidenceKind() throws {
        let doc = NotesDocumentRevision(meetingID: m, createdAt: Date(timeIntervalSince1970: 5), basedOnSummaryRevisionID: RevisionID("s1"), origin: .edited, blocks: [
            NoteBlock(kind: .heading, text: "Decisions", section: .decisions, author: .model(summaryItemID: nil, uncertain: false)),
            NoteBlock(kind: .paragraph, text: "Ship Thursday", author: .model(summaryItemID: SummaryItemID("i1"), uncertain: true), evidence: [spoken]),
            NoteBlock(kind: .bullet, text: "Earlier project: the Lyon rollout", detail: "Dana  ·  Friday", author: .user(typedAt: 754.5),
                      evidence: [.userNote(NoteEvidence(revisionID: RevisionID("d0"), blockID: NoteBlockID("b0")))]),
            NoteBlock(kind: .paragraph, text: "typed after", author: .user(typedAt: nil)),
        ])
        let back = try ContractCoding.decode(NotesDocumentRevision.self, from: ContractCoding.encode(doc))
        #expect(back == doc)
        #expect(!EvidenceRef.userNote(NoteEvidence(revisionID: RevisionID("d"), blockID: NoteBlockID("b"))).isSpoken)
        // v5 summaries that cited the scratchpad still decode.
        let old = EvidenceRef.personalNote(ScratchpadEvidence(revisionID: RevisionID("p"), start: 0, end: 3))
        #expect(try ContractCoding.decode(EvidenceRef.self, from: ContractCoding.encode(old)) == old)
    }

    @Test func editingAModelBlockMakesItTheUsersAndKeepsItsEvidence() {
        let b = NoteBlock(kind: .paragraph, text: "Ship Thursdy", author: .model(summaryItemID: SummaryItemID("i1"), uncertain: true), evidence: [spoken])
        #expect(b.isUncertain && !b.isUser)
        let e = b.editing(text: "Ship Thursday")
        #expect(e.id == b.id && e.isUser && !e.isUncertain && e.evidence == [spoken] && e.author == .user(typedAt: nil))
        #expect(b.editing(text: b.text) == b, "no change, still the model's")
        let typed = NoteBlock(kind: .bullet, text: "a", author: .user(typedAt: 12)).editing(text: "ab")
        #expect(typed.author == .user(typedAt: 12), "a user block keeps when it was first typed")
    }

    @Test func composerKeepsUncitedUserLinesVerbatimUnderAlsoNoted() {
        let cited = NoteBlock(kind: .paragraph, text: "The earlier project was the Lyon rollout", author: .user(typedAt: 60))
        let kept = NoteBlock(kind: .bullet, text: "  call the vendor  ", author: .user(typedAt: nil))
        let blank = NoteBlock(kind: .paragraph, text: "   ", author: .user(typedAt: nil))
        let s = summary(SummaryContent(overview: [SummaryItem(kind: .overview, text: "They reviewed the rollout.",
                                                               evidence: [spoken, .userNote(NoteEvidence(revisionID: RevisionID("d"), blockID: cited.id))])],
                                       actionItems: [SummaryItem(kind: .actionItem, text: "Send the plan", evidence: [spoken], owner: "Dana")]))
        let doc = NotesComposer.compose(summary: s, userBlocks: [cited, kept, blank], meetingID: m, createdAt: Date())
        #expect(doc.basedOnSummaryRevisionID == s.id && doc.origin == .generated)
        #expect(doc.blocks.compactMap(\.section) == [.overview, .nextSteps, .alsoNoted])
        #expect(doc.blocks.last == kept, "kept word for word, same ID and author")
        #expect(!doc.blocks.contains { $0.id == cited.id }, "a cited line lives on through the item citing it")
        #expect(!doc.blocks.contains { $0.id == blank.id })
        #expect(doc.blocks.first { $0.text == "Send the plan" }?.detail == "Dana  ·  no date stated")
        // Without generated notes the user's lines are the whole document, without an "Also noted" heading.
        let plain = NotesComposer.compose(summary: nil, userBlocks: [kept], meetingID: m, createdAt: Date())
        #expect(plain.blocks == [kept])
    }

    @Test func plainTextBecomesUserBlocks() {
        let blocks = NotesComposer.userBlocks(fromText: "# Client\n\n- Lyon rollout\n* budget\n• owner\n#hashtag stays text\nplain line\n", typedAt: 3)
        #expect(blocks.map(\.kind) == [.heading, .bullet, .bullet, .bullet, .paragraph, .paragraph])
        #expect(blocks.map(\.text) == ["Client", "Lyon rollout", "budget", "owner", "#hashtag stays text", "plain line"])
        #expect(blocks.allSatisfy { $0.author == .user(typedAt: 3) })
    }
}
