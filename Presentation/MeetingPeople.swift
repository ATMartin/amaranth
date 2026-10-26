import Foundation
public import Domain

/// The header's people chip and its names editor (T50). Free text for now; calendar people arrive with Milestone O.
public enum MeetingPeople {
    /// Names typed one per line or separated by commas, trimmed and de-duplicated ignoring case. A name already on the
    /// meeting keeps its source, so editing never turns calendar people into manual ones.
    public static func parse(_ text: String, keeping existing: [Person] = []) -> [Person] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "\n" || $0 == "," }).compactMap { part -> Person? in
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            let source = existing.first { $0.name.lowercased() == name.lowercased() }?.source ?? .manual
            return Person(name: name, source: source)
        }
    }

    /// The editor's starting text: one name per line.
    public static func editableText(_ people: [Person]) -> String { people.map(\.name).joined(separator: "\n") }

    /// Chip label: "Add people…" when empty, up to two names, then "+N".
    public static func chipLabel(_ people: [Person]) -> String {
        guard !people.isEmpty else { return "Add people…" }
        let shown = people.prefix(2).map(\.name).joined(separator: ", ")
        return people.count > 2 ? "\(shown) +\(people.count - 2)" : shown
    }

    /// Tooltip and VoiceOver text: every name.
    public static func fullList(_ people: [Person]) -> String {
        people.isEmpty ? "No people added" : "People: " + people.map(\.name).joined(separator: ", ")
    }
}
