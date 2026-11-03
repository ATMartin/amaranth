import Foundation
public import Domain
import CryptoKit

/// A citation into a meeting (spec 0009 §1):
/// `amaranth://meeting/<uuid>` for the meeting, or with `?source=…&ref=…&revision=…` for one passage:
/// - `source=transcript&ref=<segment>&word=<first word>&revision=<transcript revision>&h=<line hash>`
/// - `source=notes|userNote&ref=<block>&revision=<notes revision>&h=<line hash>`
/// `h` is a short hash of the cited line's text as shown, so a corrected or edited line reads as changed instead of
/// silently pointing at different words. A URL only names a place: it grants no access, carries no content, and
/// resolves against current content only.
public struct SourceURL: Hashable, Sendable {
    public enum Source: String, Sendable, CaseIterable { case transcript, notes, userNote }

    public var meetingID: MeetingID
    public var source: Source?
    public var ref: String?
    public var word: String?
    public var revision: String?
    public var hash: String?

    public static let scheme = "amaranth"
    static let allowedParameters: Set<String> = ["source", "ref", "word", "revision", "h"]

    public init(meetingID: MeetingID, source: Source? = nil, ref: String? = nil, word: String? = nil, revision: String? = nil, hash: String? = nil) {
        self.meetingID = meetingID; self.source = source; self.ref = ref; self.word = word; self.revision = revision; self.hash = hash
    }

    /// The URL text. Every component is from the validated character set, so nothing needs escaping.
    public var string: String {
        var s = "\(Self.scheme)://meeting/\(meetingID.rawValue)"
        guard let source else { return s }
        var q = ["source=\(source.rawValue)"]
        if let ref { q.append("ref=\(ref)") }
        if let word { q.append("word=\(word)") }
        if let revision { q.append("revision=\(revision)") }
        if let hash { q.append("h=\(hash)") }
        s += "?" + q.joined(separator: "&")
        return s
    }

    /// Short hash of a line's shown text (16 hex digits of SHA-256).
    public static func lineHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Identifiers: letters, digits and `-_.:`, 1…128 characters.
    static func isIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= AccessLimits.maxIdentifierLength
            && s.unicodeScalars.allSatisfy { ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || "-_.:".unicodeScalars.contains($0) }
    }

    /// Parses and validates a citation URL. Anything unexpected is rejected: another scheme or host, credentials, a
    /// port, a fragment, extra path segments, a meeting ID that is not a UUID, unknown or repeated parameters,
    /// identifiers outside the allowed characters, or a passage without its revision.
    public static func parse(_ text: String) -> Result<SourceURL, AccessError> {
        func bad(_ why: String) -> Result<SourceURL, AccessError> { .failure(.invalidRequest(why)) }
        guard text.utf8.count <= AccessLimits.maxURLLength else { return bad("url too long") }
        guard let c = URLComponents(string: text) else { return bad("not a URL") }
        guard c.scheme?.lowercased() == scheme else { return bad("scheme") }
        guard c.host?.lowercased() == "meeting" else { return bad("host") }
        guard c.user == nil, c.password == nil, c.port == nil, c.fragment == nil else { return bad("url parts") }
        let path = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, path[0].isEmpty, let uuid = UUID(uuidString: String(path[1])) else { return bad("meeting id") }
        var url = SourceURL(meetingID: MeetingID(uuid.uuidString.lowercased()))
        var seen = Set<String>()
        // Raw (percent-encoded) values: a valid value never needs escaping, so any `%` is rejected by the identifier check.
        for item in c.percentEncodedQueryItems ?? [] {
            guard allowedParameters.contains(item.name) else { return bad("parameter \(item.name.prefix(32))") }
            guard seen.insert(item.name).inserted else { return bad("repeated \(item.name)") }
            guard let v = item.value, isIdentifier(v) else { return bad("value of \(item.name)") }
            switch item.name {
            case "source":
                guard let s = Source(rawValue: v) else { return bad("source") }
                url.source = s
            case "ref": url.ref = v
            case "word": url.word = v
            case "revision": url.revision = v
            case "h":
                guard v.count == 16, v.allSatisfy(\.isHexDigit) else { return bad("h") }
                url.hash = v.lowercased()
            default: break
            }
        }
        if c.query != nil, c.query?.isEmpty == true { return bad("empty query") }
        if url.source == nil {
            guard seen.isEmpty else { return bad("parameters without source") }
        } else {
            guard url.ref != nil, url.revision != nil else { return bad("source needs ref and revision") }
            if url.source != .transcript, url.word != nil { return bad("word is for transcript sources") }
        }
        return .success(url)
    }
}

/// What a citation points at now.
public enum CitationResolution: Equatable, Sendable {
    /// Resolves to this place in the current content. `start` is the transcript line's time.
    case current(CitationTarget)
    /// The meeting exists but the cited passage changed or is gone: offer the meeting, never a nearby line.
    case changed(meetingID: MeetingID, title: String)
    /// No such meeting (deleted, or never in this library).
    case unavailable
    case invalid(String)
}

public struct CitationTarget: Equatable, Sendable {
    public var meetingID: MeetingID
    public var title: String
    /// nil: the meeting itself.
    public var source: SourceURL.Source?
    public var ref: String?
    public var word: String?
    public var startNs: Int64?
}

extension MeetingSnapshot {
    /// Resolves `url` (already parsed, for this meeting) against this snapshot. A passage resolves when it is shown now
    /// and either its revision is the current one or its text hash still matches; otherwise it is `changed`.
    public func resolve(_ url: SourceURL) -> CitationResolution {
        guard url.meetingID.rawValue == meetingID else { return .unavailable }
        let id = MeetingID(meetingID)
        guard let source = url.source, let ref = url.ref else {
            return .current(CitationTarget(meetingID: id, title: title, source: nil, ref: nil, word: nil, startNs: nil))
        }
        func check(currentRevision: String?, text: String) -> Bool {
            if let h = url.hash, h != SourceURL.lineHash(text) { return false }
            return url.revision == currentRevision || url.hash != nil
        }
        switch source {
        case .transcript:
            guard let line = transcript.first(where: { $0.segmentID == ref && (url.word == nil || $0.wordID == url.word) }),
                  check(currentRevision: revisions.transcript, text: line.text)
            else { return .changed(meetingID: id, title: title) }
            return .current(CitationTarget(meetingID: id, title: title, source: .transcript, ref: ref, word: line.wordID, startNs: line.startNs))
        case .notes, .userNote:
            guard let block = notes.first(where: { $0.blockID == ref }),
                  check(currentRevision: revisions.notes, text: NoteLineText.hashed(block.text, block.detail))
            else { return .changed(meetingID: id, title: title) }
            return .current(CitationTarget(meetingID: id, title: title, source: block.author == "user" ? .userNote : .notes, ref: ref, word: nil, startNs: nil))
        }
    }
}

enum NoteLineText {
    /// The text a notes citation hashes: the line, and its detail line when it has one.
    static func hashed(_ text: String, _ detail: String?) -> String { detail.map { text + "\n" + $0 } ?? text }
}
