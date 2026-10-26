import SwiftUI
import Domain
import Presentation

/// Live provisional text while recording. Clearly marked as provisional; tentative words are dimmed; no speakers are
/// guessed (only the source track is shown).
struct LiveTranscriptView: View {
    @Environment(LiveTextModel.self) private var live
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder
        VStack(alignment: .leading, spacing: 0) {
            TextField("Private scratchpad (only on this Mac)", text: $recorder.scratchpad, axis: .vertical).lineLimit(2...6)
                .textFieldStyle(.roundedBorder).font(.callout).padding([.horizontal, .top])
            HStack {
                Label("Live text — provisional", systemImage: "waveform").font(.headline)
                Spacer()
                switch live.status {
                case .running: if let p = live.state.percentile(0.5) { Text(String(format: "about %.0f s behind", p)).font(.caption).foregroundStyle(.secondary) }
                case .paused(let why), .unavailable(let why): Text(why).font(.caption).foregroundStyle(.orange)
                case .off: EmptyView()
                }
            }
            .padding()
            Text("The final transcript, with speakers, is made after you stop. Audio is saved either way.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            Divider().padding(.top, 8)
            ScrollViewReader { proxy in
                List {
                    let lines = live.state.lines
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(TranscriptRows.clock(line.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                            Text(line.source == .microphone ? "MIC" : "SYS").font(.caption2.bold()).padding(.horizontal, 4)
                                .background(.quaternary, in: .rect(cornerRadius: 3))
                            Text(line.text).foregroundStyle(line.tentative ? .secondary : .primary).italic(line.tentative)
                        }
                        .id(i)
                    }
                }
                .listStyle(.inset)
                .onChange(of: live.state.lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            if live.state.lines.isEmpty {
                Text(recorder.state == .recording ? "Listening… text appears a few seconds after speech." : "Not recording.")
                    .foregroundStyle(.secondary).padding()
            }
        }
    }
}
