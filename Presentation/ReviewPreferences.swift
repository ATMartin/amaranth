/// The global "Details" switch on the meeting screen: off = quick review (no evidence links, gap rows or badges),
/// on = everything. One persisted preference shared by Notes, Transcript and the header — never per meeting.
public enum ReviewPreferences {
    /// UserDefaults key. Renaming it silently resets every user's choice; a test pins it.
    public static let showDetailsKey = "reviewShowDetails"
    public static let showDetailsDefault = false
}
