/// Meeting rename rules (T26): titles are trimmed; an empty or unchanged title keeps the old one.
public enum MeetingTitle {
    /// The title to store, or nil when nothing should change.
    public static func renamed(from current: String, to proposed: String) -> String? {
        let t = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == current ? nil : t
    }
}
