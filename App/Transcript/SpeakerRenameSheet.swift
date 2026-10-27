import SwiftUI
import Domain
import Presentation

/// Rename a speaker (T38), with the meeting's people as one-click suggestions above the field (T60). A suggestion fills
/// the name and saves, exactly like typing it and pressing Save; nothing is named automatically.
struct SpeakerRenameSheet: View {
    let speaker: Speaker
    @Binding var text: String
    let suggestions: [String]
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(speaker.label)").font(.headline)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("People in this meeting").font(.caption).foregroundStyle(.secondary)
                    // Not lazy: a meeting lists a handful of people, and a lazy grid doesn't lay out offscreen (ui-render).
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(Array(stride(from: 0, to: suggestions.count, by: 3)), id: \.self) { i in
                            GridRow {
                                ForEach(suggestions[i..<min(i + 3, suggestions.count)], id: \.self) { name in
                                    Button {
                                        text = name
                                        save()
                                        dismiss()
                                    } label: {
                                        Label(name, systemImage: "person").lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                                    }
                                    .help("Name \(speaker.label) “\(name)”")
                                }
                            }
                        }
                    }
                }
            }
            TextField("Rename \(speaker.label)", text: $text, axis: .vertical).lineLimit(1...6).frame(minWidth: 380)
            Text("Leave empty to go back to “\(speaker.label)”. Names are only what you choose or type.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
