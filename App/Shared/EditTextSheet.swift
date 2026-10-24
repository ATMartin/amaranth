import SwiftUI

/// A one-field edit sheet: correct transcript text, rename a speaker, rename a meeting.
struct EditTextSheet: View {
    let title: String
    @Binding var text: String
    let help: String
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(title, text: $text, axis: .vertical).lineLimit(1...6).frame(minWidth: 380)
            Text(help).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
