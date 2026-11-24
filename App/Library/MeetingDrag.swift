import SwiftUI
import UniformTypeIdentifiers
import Domain

extension UTType {
    /// A meeting dragged inside Amaranth (T41), declared in Info.plist (project.yml). Other apps don't accept it.
    static let amaranthMeeting = UTType(exportedAs: "com.alexmartin.amaranth.meeting-id")
}

/// A sidebar card's drag payload (T41): the meeting's ID only, never its content. Kept in the app, not on Domain's
/// MeetingID, so the frozen contracts don't depend on SwiftUI.
struct DraggedMeeting: Codable, Transferable {
    var id: String
    init(_ id: MeetingID) { self.id = id.rawValue }
    var meetingID: MeetingID { MeetingID(id) }
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .amaranthMeeting) }
}
