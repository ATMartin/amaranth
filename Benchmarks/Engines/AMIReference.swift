import Foundation

/// AMI manual word annotations (`<meeting>.<channel>.words.xml`), merged across channels in time order.
/// Punctuation tokens and non-word elements (vocal sounds, disfluency markers, gaps) are excluded.
public struct AMIReference: Sendable {
    public struct Word: Sendable, Hashable, Codable {
        public var text: String
        public var start: Double
        public var end: Double
        public var channel: String
    }

    public let meeting: String
    public let words: [Word]

    public init(directory: URL, meeting: String) throws {
        self.meeting = meeting
        let wordsDir = directory.appending(path: "words")
        var all: [Word] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: wordsDir.path) where file.hasSuffix(".words.xml") {
            let channel = file.split(separator: ".").dropFirst().first.map(String.init) ?? "?"
            let parser = WordsXMLParser(channel: channel)
            let xml = XMLParser(contentsOf: wordsDir.appending(path: file))!
            xml.delegate = parser
            guard xml.parse() else { throw BenchError.audio("bad AMI xml \(file): \(String(describing: xml.parserError))") }
            all += parser.words
        }
        words = all.sorted { ($0.start, $0.channel) < ($1.start, $1.channel) }
    }

    public func text(from start: Double = 0, to end: Double = .infinity) -> String {
        words.filter { $0.start >= start && $0.start < end }.map(\.text).joined(separator: " ")
    }
}

private final class WordsXMLParser: NSObject, XMLParserDelegate {
    let channel: String
    var words: [AMIReference.Word] = []
    private var current: (start: Double, end: Double, punc: Bool)?
    private var text = ""

    init(channel: String) { self.channel = channel }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        guard name == "w", let s = a["starttime"].flatMap(Double.init), let e = a["endtime"].flatMap(Double.init) else { return }
        current = (s, e, a["punc"] == "true")
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if current != nil { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "w", let c = current else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.punc && !t.isEmpty { words.append(.init(text: t, start: c.start, end: c.end, channel: channel)) }
        current = nil
    }
}
