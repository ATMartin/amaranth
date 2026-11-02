import SwiftUI
import Domain
import Presentation

/// Live provisional text while recording, under just the meeting title; tentative words are dimmed; no speakers are
/// guessed (only the source track is shown).
struct LiveTranscriptView: View {
    @Environment(LiveTextModel.self) private var live
    @Environment(RecorderModel.self) private var recorder
    @Environment(LibraryModel.self) private var library
    @FocusState private var notesFocused: Bool

    var body: some View {
        @Bindable var recorder = recorder
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                // Just the title (user, 2026-11-02): no "Live text / Provisional" eyebrow or note about the final transcript.
                Text(meetingTitle).appFont(.display).lineLimit(1).foregroundStyle(Color.brandText)
                Spacer()
                switch live.status {
                case .running: if let p = live.state.percentile(0.5) { Text(String(format: "about %.0f s behind", p)).font(.caption).foregroundStyle(Color.brandSecondary) }
                case .paused(let why), .unavailable(let why): Text(why).font(.caption).foregroundStyle(Color.statusAttention)
                case .off: EmptyView()
                }
                Toggle(isOn: $recorder.notesOpen) { Label("Notes", systemImage: "note.text") }
                    .toggleStyle(BrandChipToggleStyle())
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Notes for this meeting, used when its notes are generated (⌘⇧N)")
            }
            .padding(.horizontal, AppStyle.double + 8).padding(.top, AppStyle.double + 4).padding(.bottom, AppStyle.half)
            // Inline above the transcript, never a modal; lines go into the meeting's notes (saved every few seconds and at
            // Stop) and into the notes generated after Stop.
            if recorder.notesOpen {
                TextField("Notes: one line per thought, used when this meeting's notes are generated",
                          text: Binding(get: { recorder.notes.text }, set: { recorder.typeNotes($0) }), axis: .vertical).lineLimit(2...6)
                    .textFieldStyle(.roundedBorder).font(.callout).padding(.horizontal, AppStyle.double + 8).padding(.top)
                    .focused($notesFocused)
                    // Only when empty: focusing selects all existing text, and the next keystroke would replace it.
                    .onAppear { if recorder.notes.text.isEmpty { notesFocused = true } }
            }
            Hairline().padding(.top, AppStyle.grid + 4)
            ScrollViewReader { proxy in
                List {
                    let lines = live.state.lines
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: AppStyle.double) {
                            Text(TranscriptRows.clock(line.start)).appFont(.caption, monospacedDigit: true).foregroundStyle(Color.brandSecondary)
                                .frame(width: TranscriptRowView.timeWidth, alignment: .leading)
                            SourceIcon(source: line.source)
                            Text(line.text).appFont(.body).foregroundStyle(line.tentative ? Color.brandSecondary : Color.brandText).italic(line.tentative)
                        }
                        .id(i)
                        .listRowInsets(EdgeInsets(top: 3, leading: AppStyle.double + 8, bottom: 3, trailing: AppStyle.double + 8))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: live.state.lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
                // Where the first line will appear, not at the bottom of the window.
                .overlay(alignment: .topLeading) {
                    if live.state.lines.isEmpty {
                        Text(recorder.state == .recording ? "Listening… text appears a few seconds after speech." : "Not recording.")
                            .appFont(.callout).foregroundStyle(Color.brandSecondary).padding(.horizontal, AppStyle.double + 8).padding(.vertical)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The stored title (it follows a calendar link), else the one the recording started with.
    var meetingTitle: String {
        library.items.first { $0.id == recorder.meetingID }?.title ?? recorder.automaticTitle ?? (recorder.title.isEmpty ? "Recording" : recorder.title)
    }
}
