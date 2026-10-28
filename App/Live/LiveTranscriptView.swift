import SwiftUI
import Domain
import Presentation

/// Live provisional text while recording. Clearly marked as provisional; tentative words are dimmed; no speakers are
/// guessed (only the source track is shown).
struct LiveTranscriptView: View {
    @Environment(LiveTextModel.self) private var live
    @Environment(RecorderModel.self) private var recorder
    @Environment(LibraryModel.self) private var library
    @FocusState private var scratchpadFocused: Bool

    var body: some View {
        @Bindable var recorder = recorder
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AppStyle.half) {
                    Eyebrow(text: "Live text", detail: "Provisional")
                    Text(meetingTitle).appFont(.display).lineLimit(1).foregroundStyle(Color.brandText)
                }
                Spacer()
                switch live.status {
                case .running: if let p = live.state.percentile(0.5) { Text(String(format: "about %.0f s behind", p)).font(.caption).foregroundStyle(Color.brandSecondary) }
                case .paused(let why), .unavailable(let why): Text(why).font(.caption).foregroundStyle(Color.statusAttention)
                case .off: EmptyView()
                }
                Toggle(isOn: $recorder.scratchpadOpen) { Label("Scratchpad", systemImage: "note.text") }
                    .toggleStyle(BrandChipToggleStyle())
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Private scratchpad for this meeting (⌘⇧N)")
            }
            .padding(.horizontal, AppStyle.double + 8).padding(.top, AppStyle.double + 4).padding(.bottom, AppStyle.half)
            Text("The final transcript, with speakers, is made after you stop. Audio is saved either way.")
                .appFont(.caption).foregroundStyle(Color.brandSecondary).padding(.horizontal, AppStyle.double + 8)
            // Inline above the transcript, never a modal; text keeps flowing into the recorder and is saved at Stop.
            if recorder.scratchpadOpen {
                TextField("Private scratchpad (only on this Mac)", text: $recorder.scratchpad, axis: .vertical).lineLimit(2...6)
                    .textFieldStyle(.roundedBorder).font(.callout).padding(.horizontal, AppStyle.double + 8).padding(.top)
                    .focused($scratchpadFocused)
                    // Only when empty: focusing selects all existing text, and the next keystroke would replace it.
                    .onAppear { if recorder.scratchpad.isEmpty { scratchpadFocused = true } }
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
