import SwiftUI
import Domain
import Presentation

/// Virtualized transcript (`List` reuses rows, so a two-hour meeting scrolls smoothly). Click a time to play from it;
/// right-click a row to correct text or change its speaker; the speaker bar renames and merges speakers. Gaps are rows:
/// with Details off (skim mode, T25) they draw as hairlines and flags as icons; with Details on, in full.
struct TranscriptPane: View {
    let detail: MeetingDetail
    @Environment(LibraryModel.self) private var library
    @Environment(PlaybackModel.self) private var playback
    @State private var correcting: TranscriptRow?
    @State private var correction = ""
    @State private var renaming: Speaker?
    @State private var newName = ""
    @State private var selectedRow: String?
    @Environment(\.showDetails) private var showDetails

    var speakers: [Speaker] { detail.displayTranscript?.speakers ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if detail.showingProvisional {
                Label("Live text (provisional). The final transcript with speakers replaces it after processing; edits are available then.",
                      systemImage: "waveform.badge.magnifyingglass").font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.08))
            }
            SpeakerBar(speakers: speakers, rename: { renaming = $0; newName = $0.displayName ?? "" }, merge: merge)
            PlaybackBar(detail: detail)
            Divider()
            if detail.rows.isEmpty {
                ContentUnavailableView("No transcript yet", systemImage: "text.quote",
                                       description: Text(detail.transcript == nil ? "The transcript appears here after processing. The audio is saved." : "No speech was detected."))
            } else {
                ScrollViewReader { proxy in
                    List(showDetails ? detail.rows : TranscriptRows.skim(detail.rows), selection: $selectedRow) { row in
                        TranscriptRowView(row: row, playable: detail.playbackUnavailableReason == nil) { playback.play(from: row.start.seconds) }
                            .tag(row.id)
                            .id(row.id)
                            .listRowBackground(row.id == library.focusRowID ? Color.accentColor.opacity(0.15) : nil)
                            .contextMenu { menu(row) }
                    }
                    .listStyle(.inset)
                    .environment(\.defaultMinListRowHeight, 8)   // hairline gap rows in skim mode
                    .onChange(of: library.focusRowID, initial: true) { _, id in
                        guard let id else { return }
                        // Next run-loop turn: changing the selection while the table is updating is reentrant in AppKit.
                        Task { @MainActor in
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                            selectedRow = id
                        }
                    }
                }
            }
            if !detail.editsNeedingReview.isEmpty {
                Label("\(detail.editsNeedingReview.count) of your edits could not be re-applied after reprocessing. They are kept; please check the speakers.",
                      systemImage: "exclamationmark.bubble").font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
            }
        }
        .sheet(item: $correcting) { row in
            EditTextSheet(title: "Correct text", text: $correction, help: "The original recognition is kept; your correction is shown, searched and exported.") {
                apply { try $0.correct(row, text: correction) }
            }
        }
        .sheet(item: $renaming) { s in
            EditTextSheet(title: "Rename \(s.label)", text: $newName, help: "Leave empty to go back to “\(s.label)”. Names are only what you type.") {
                apply { $0.rename(s.id, to: newName) }
            }
        }
    }

    @ViewBuilder func menu(_ row: TranscriptRow) -> some View {
        if row.range != nil, !detail.showingProvisional {
            Button("Correct Text…") { correction = row.text; correcting = row }
            Menu("Assign to Speaker") {
                ForEach(speakers) { s in Button(s.shownName) { apply { try $0.reassign(row, to: .existing(s.id)) } } }
                Divider()
                Button("New Speaker") { apply { try $0.reassign(row, to: $0.newSpeakerTarget()) } }
                Button("Unknown Speaker") { apply { try $0.reassign(row, to: .unknown) } }
            }
            Button("Mark Speaker as Uncertain") { apply { try $0.markUncertain(row) } }
            if detail.playbackUnavailableReason == nil { Button("Play from Here") { playback.play(from: row.start.seconds) } }
        }
    }

    func merge(_ source: Speaker, into target: Speaker) { apply { try $0.merge([source.id], into: target.id) } }

    func apply(_ make: (EditComposer) throws -> UserEdit) {
        guard let t = detail.transcript else { return }
        let composer = EditComposer(meetingID: detail.meeting.id, revision: t, existing: detail.edits)
        if let e = try? make(composer) { library.apply(e) }
    }
}

struct TranscriptRowView: View {
    let row: TranscriptRow
    let playable: Bool
    let play: () -> Void
    @Environment(\.showDetails) private var showDetails

    var body: some View {
        if row.isGap, !showDetails {
            Rectangle().fill(.orange.opacity(0.45)).frame(height: 1)
                .padding(.vertical, 3).frame(maxWidth: .infinity).contentShape(Rectangle())
                .help(TranscriptRows.gapDescription(row))
                .accessibilityElement().accessibilityLabel(TranscriptRows.gapDescription(row))
        } else if case .gap(let reason) = row.kind {
            Label("\(TranscriptRows.clock(row.start))–\(TranscriptRows.clock(row.end)) · \(reason)", systemImage: "waveform.slash")
                .font(.callout).foregroundStyle(.orange)
                .accessibilityLabel("Gap from \(TranscriptRows.clock(row.start)) to \(TranscriptRows.clock(row.end)): \(reason)")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(TranscriptRows.clock(row.start), action: play)
                    .buttonStyle(.plain).monospacedDigit().foregroundStyle(playable ? Color.accentColor : .secondary)
                    .disabled(!playable).help(playable ? "Play from here" : "Playback unavailable")
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.speakerLabel).bold().foregroundStyle(row.assignment == .unknown ? .secondary : .primary)
                        if showDetails {
                            Text(row.source == .microphone ? "MIC" : "SYS").font(.caption2.bold()).padding(.horizontal, 4)
                                .background(.quaternary, in: .rect(cornerRadius: 3)).help(row.source == .microphone ? "Your microphone" : "System audio")
                        }
                        if row.flags.contains(.overlap) { flag("overlap", "person.2.wave.2", "Several people spoke at once") }
                        if row.flags.contains(.uncertainSpeaker) { flag("speaker uncertain", "questionmark.circle", "Speaker attribution is uncertain") }
                        if row.flags.contains(.probableEcho) { flag("echo?", "speaker.wave.2", "Probably your speakers picked up by the mic; kept, not deleted") }
                        if row.flags.contains(.questionableText) { flag("check text", "exclamationmark.triangle", "Speech recognition may have garbled this") }
                        if row.flags.contains(.corrected) { flag("edited", "pencil", "You corrected this text") }
                    }
                    Text(row.text).textSelection(.enabled)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Icon and caption with Details on; icon only (same tooltip, caption as the VoiceOver label) in skim mode.
    @ViewBuilder func flag(_ text: String, _ icon: String, _ help: String) -> some View {
        if showDetails {
            Label(text, systemImage: icon).font(.caption2).foregroundStyle(.orange).help(help).labelStyle(.titleAndIcon)
        } else {
            Label(text, systemImage: icon).font(.caption2).foregroundStyle(.orange).help(help).labelStyle(.iconOnly)
        }
    }
}

struct SpeakerBar: View {
    let speakers: [Speaker]
    let rename: (Speaker) -> Void
    let merge: (Speaker, Speaker) -> Void

    var body: some View {
        if !speakers.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    Text("Speakers").font(.caption).foregroundStyle(.secondary)
                    ForEach(speakers) { s in
                        Menu {
                            Button("Rename…") { rename(s) }
                            Menu("Merge Into") { ForEach(speakers.filter { $0.id != s.id }) { t in Button(t.shownName) { merge(s, t) } } }
                        } label: { Text(s.shownName) }
                        .menuStyle(.button).controlSize(.small).fixedSize()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
    }
}

struct PlaybackBar: View {
    let detail: MeetingDetail
    @Environment(PlaybackModel.self) private var playback

    var body: some View {
        HStack {
            if let reason = detail.playbackUnavailableReason {
                Label(reason, systemImage: "speaker.slash").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                    .keyboardShortcut(.space, modifiers: []).help(playback.isPlaying ? "Pause" : "Play")
                Text(TranscriptRows.clock(SessionTime(nanoseconds: Int64(playback.position * 1e9)))).monospacedDigit().font(.caption)
                if let e = playback.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }
}

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
