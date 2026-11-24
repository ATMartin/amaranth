public import Foundation

/// One current transcript line as chunking sees it (already corrected/trimmed: hidden words never reach here).
public struct ChunkSourceLine: Hashable, Sendable {
    public var segmentID: TranscriptSegmentID
    /// Shown speaker name(s), nil when unknown.
    public var speaker: String?
    public var words: [String]
    /// Current word IDs, parallel to `words` (for exact citations).
    public var wordIDs: [WordID]
    public var start: SessionTime
    public init(segmentID: TranscriptSegmentID, speaker: String?, words: [String], wordIDs: [WordID], start: SessionTime) {
        self.segmentID = segmentID; self.speaker = speaker; self.words = words; self.wordIDs = wordIDs; self.start = start
    }
}

/// A piece of one line inside a chunk: the whole line, or a word range of an oversized one.
public struct ChunkSpan: Hashable, Sendable, Codable {
    public var segmentID: TranscriptSegmentID
    public var firstWord: WordID
    public var lastWord: WordID
    public init(segmentID: TranscriptSegmentID, firstWord: WordID, lastWord: WordID) {
        self.segmentID = segmentID; self.firstWord = firstWord; self.lastWord = lastWord
    }
}

public struct TranscriptChunk: Hashable, Sendable {
    /// Position within the meeting, 0…
    public var ordinal: Int
    /// Encoder input: `Speaker: text` lines.
    public var text: String
    public var spans: [ChunkSpan]
    /// Index range into the source lines (for context expansion).
    public var firstLine: Int
    public var lastLine: Int
    public var start: SessionTime
    /// Identity of the encoder input (chunking version + text); unchanged text keeps its vector.
    public var contentHash: String
}

/// chunk-v1 (spec 0010 "Indexing and data lifecycle"): consecutive current lines in transcript order, grouped until the
/// chunk reaches the target size, never past the maximum; one line of overlap with the previous chunk; a line longer than
/// the maximum is split into word windows, never truncated. Sizes are estimated tokens (`ContextualLimits`).
public enum Chunker {
    /// `title`: the meeting title, written as a first `Meeting: …` line of every chunk's encoder input (chunk-v2), so a
    /// passage carries its meeting's topic; a title change re-chunks.
    public static func chunks(_ lines: [ChunkSourceLine], title: String? = nil, version: String = ChunkingVersion.current,
                              target: Int = ContextualLimits.chunkTargetTokens, maximum: Int = ContextualLimits.chunkMaxTokens) -> [TranscriptChunk] {
        struct Piece { var line: Int; var speaker: String?; var words: ArraySlice<String>; var ids: ArraySlice<WordID>; var seg: TranscriptSegmentID; var start: SessionTime }
        // Oversized lines become several pieces of at most `maxWords` words.
        let maxWords = maximum * 3 / 4 - 8
        var pieces: [Piece] = []
        for (i, l) in lines.enumerated() where !l.words.isEmpty && l.words.count == l.wordIDs.count {
            var lo = 0
            while lo < l.words.count {
                let hi = min(l.words.count, lo + maxWords)
                pieces.append(Piece(line: i, speaker: l.speaker, words: l.words[lo..<hi], ids: l.wordIDs[lo..<hi], seg: l.segmentID, start: l.start))
                lo = hi
            }
        }
        func tokens(_ p: Piece) -> Int { ContextualLimits.estimatedTokens(words: p.words.count, lines: 1) }
        let header = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : "Meeting: " + String($0.prefix(120)) + "\n" } ?? ""
        func render(_ ps: ArraySlice<Piece>) -> String {
            header + ps.map { ($0.speaker ?? "Unknown speaker") + ": " + $0.words.joined(separator: " ") }.joined(separator: "\n")
        }
        var out: [TranscriptChunk] = []
        var i = 0
        while i < pieces.count {
            var j = i
            var size = 0
            while j < pieces.count {
                let t = tokens(pieces[j])
                if j > i, size + t > maximum { break }
                size += t
                j += 1
                if size >= target { break }
            }
            out.append(make(pieces[i..<j], ordinal: out.count, version: version, render: render))
            if j >= pieces.count { break }
            // Overlap: the next chunk repeats the last piece, unless this chunk is that one piece.
            i = j - i > ContextualLimits.chunkOverlapLines ? j - ContextualLimits.chunkOverlapLines : j
        }
        return out

        func make(_ ps: ArraySlice<Piece>, ordinal: Int, version: String, render: (ArraySlice<Piece>) -> String) -> TranscriptChunk {
            let text = render(ps)
            return TranscriptChunk(ordinal: ordinal, text: text,
                                   spans: ps.map { ChunkSpan(segmentID: $0.seg, firstWord: $0.ids.first!, lastWord: $0.ids.last!) },
                                   firstLine: ps.first!.line, lastLine: ps.last!.line, start: ps.first!.start,
                                   contentHash: StableHash.hex(version + "\u{1f}" + text))
        }
    }
}
