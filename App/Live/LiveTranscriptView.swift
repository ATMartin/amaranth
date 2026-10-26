import SwiftUI
import Domain
import Presentation

/// Live provisional text while recording. Clearly marked as provisional; tentative words are dimmed; no speakers are
/// guessed (only the source track is shown).
struct LiveTranscriptView: View {
    @Environment(LiveTextModel.self) private var live
    @Environment(RecorderModel.self) private var recorder
    @FocusState private var scratchpadFocused: Bool

    var body: some View {
        @Bindable var recorder = recorder
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Live text — provisional", systemImage: "waveform").font(.headline)
                Spacer()
                switch live.status {
                case .running: if let p = live.state.percentile(0.5) { Text(String(format: "about %.0f s behind", p)).font(.caption).foregroundStyle(.secondary) }
                case .paused(let why), .unavailable(let why): Text(why).font(.caption).foregroundStyle(Color.statusAttention)
                case .off: EmptyView()
                }
                Toggle(isOn: $recorder.scratchpadOpen) { Label("Scratchpad", systemImage: "note.text") }
                    .toggleStyle(.button)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("Private scratchpad for this meeting (⌘⇧N)")
            }
            .padding()
            Text("The final transcript, with speakers, is made after you stop. Audio is saved either way.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            // Inline above the transcript, never a modal; text keeps flowing into the recorder and is saved at Stop.
            if recorder.scratchpadOpen {
                TextField("Private scratchpad (only on this Mac)", text: $recorder.scratchpad, axis: .vertical).lineLimit(2...6)
                    .textFieldStyle(.roundedBorder).font(.callout).padding([.horizontal, .top])
                    .focused($scratchpadFocused)
                    // Only when empty: focusing selects all existing text, and the next keystroke would replace it.
                    .onAppear { if recorder.scratchpad.isEmpty { scratchpadFocused = true } }
            }
            Divider().padding(.top, 8)
            ScrollViewReader { proxy in
                List {
                    let lines = live.state.lines
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(TranscriptRows.clock(line.start)).appFont(.caption, monospacedDigit: true).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                            Text(line.source == .microphone ? "MIC" : "SYS").appFont(.caption2, weight: .bold).padding(.horizontal, 4)
                                .background(.quaternary, in: .rect(cornerRadius: 3))
                            Text(line.text).appFont(.body).foregroundStyle(line.tentative ? .secondary : .primary).italic(line.tentative)
                        }
                        .id(i)
                    }
                }
                .listStyle(.inset)
                .onChange(of: live.state.lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
                // Where the first line will appear, not at the bottom of the window.
                .overlay(alignment: .topLeading) {
                    if live.state.lines.isEmpty {
                        Text(recorder.state == .recording ? "Listening… text appears a few seconds after speech." : "Not recording.")
                            .foregroundStyle(.secondary).padding()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
