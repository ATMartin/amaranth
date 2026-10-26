import SwiftUI
import Domain
import Presentation

/// Virtualized transcript (`List` reuses rows, so a two-hour meeting scrolls smoothly) in three columns: time, speaker
/// (disc and name on the first row of each same-speaker run, T35), text. Click a time to play from it; right-click a
/// row to correct text or change its speaker; click a speaker's name to rename, merge or reassign (T38; the speaker bar
/// shows with Details on). Gaps are rows:
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
                      systemImage: "waveform.badge.magnifyingglass").appFont(.caption).padding(AppStyle.grid).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
            }
            // One compact strip (T36): playback on the left, then the speaker overview with Details on only; in skim
            // mode rename and merge live in the speaker column (T38).
            HStack(spacing: AppStyle.grid) {
                PlaybackBar(detail: detail).layoutPriority(1)
                if showDetails { SpeakerBar(speakers: speakers, rename: rename, merge: merge) }
                Spacer(minLength: 0)
            }
            Divider()
            if detail.rows.isEmpty {
                ContentUnavailableView("No transcript yet", systemImage: "text.quote",
                                       description: Text(detail.transcript == nil ? "The transcript appears here after processing. The audio is saved." : "No speech was detected."))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, AppStyle.double)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    let rows = showDetails ? detail.rows : TranscriptRows.skim(detail.rows)
                    let runStarts = TranscriptRows.runStarts(rows)
                    List(rows, selection: $selectedRow) { row in
                        TranscriptRowView(row: row, showsSpeaker: runStarts.contains(row.id), playable: detail.playbackUnavailableReason == nil,
                                          play: { playback.play(from: row.start.seconds) }, speakerMenu: speakerMenu(row))
                            // Compact rows (T36): no separators; a run's first row gets a little air above it instead.
                            .listRowInsets(EdgeInsets(top: runStarts.contains(row.id) && !row.isGap ? 3 : 0, leading: AppStyle.grid,
                                                      bottom: 0, trailing: AppStyle.grid))
                            .listRowSeparator(.hidden)
                            .tag(row.id)
                            .id(row.id)
                            .listRowBackground(row.id == library.focusRowID ? Color.accentColor.opacity(0.15) : nil)
                            .contextMenu { menu(row) }
                    }
                    .listStyle(.inset)
                    .environment(\.speakerColors, TranscriptRows.paletteIndices(speakers.map(\.id)))
                    .environment(\.defaultMinListRowHeight, 8)   // hairline gap rows in skim mode
                    // Runs on appear and on each new focus; cancelled when the focus changes or the pane goes away.
                    // Off the current update: changing the selection while the table is updating is reentrant in
                    // AppKit. Rows have estimated heights until laid out, so one scroll on a long meeting lands dozens
                    // of rows off; scroll again once the rows near the target have real heights, unless the user has
                    // selected another row meanwhile.
                    .task(id: library.focusRowID) {
                        guard let id = library.focusRowID else { return }
                        await Task.yield()
                        for pass in 0..<3 {
                            if pass > 0 {
                                try? await Task.sleep(for: .milliseconds(120))
                                guard !Task.isCancelled, selectedRow == id else { return }
                            }
                            selectedRow = id
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            if !detail.editsNeedingReview.isEmpty {
                Label("\(detail.editsNeedingReview.count) of your edits could not be re-applied after reprocessing. They are kept; please check the speakers.",
                      systemImage: "exclamationmark.bubble").appFont(.caption).padding(AppStyle.grid).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.statusAttention.opacity(AppPalette.tintOpacity))
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
            Menu("Assign to Speaker") { assignItems(row) }
            Button("Mark Speaker as Uncertain") { apply { try $0.markUncertain(row) } }
            if detail.playbackUnavailableReason == nil { Button("Play from Here") { playback.play(from: row.start.seconds) } }
        }
    }

    @ViewBuilder func assignItems(_ row: TranscriptRow) -> some View {
        ForEach(SpeakerMenu.assignTargets(for: row, in: speakers)) { s in Button(s.shownName) { apply { try $0.reassign(row, to: .existing(s.id)) } } }
        Divider()
        Button("New Speaker") { apply { try $0.reassign(row, to: $0.newSpeakerTarget()) } }
        if row.assignment != .unknown { Button("Unknown Speaker") { apply { try $0.reassign(row, to: .unknown) } } }
    }

    /// Menu behind the speaker disc and name (T38): the SpeakerBar's Rename… and Merge Into for the row's speaker (one
    /// submenu per speaker on overlap rows), and Assign This Line To from the row menu. Nil while the text is
    /// provisional (no edits yet), so the name is plain text then.
    func speakerMenu(_ row: TranscriptRow) -> (() -> AnyView)? {
        guard !detail.showingProvisional, detail.transcript != nil, !row.isGap else { return nil }
        return {
            let subjects = SpeakerMenu.subjects(of: row, in: speakers)
            return AnyView(Group {
                if subjects.count == 1, let s = subjects.first {
                    speakerItems(s)
                } else {
                    ForEach(subjects) { s in Menu(s.shownName) { speakerItems(s) } }
                }
                if row.range != nil {
                    if !subjects.isEmpty { Divider() }
                    Menu("Assign This Line To") { assignItems(row) }
                }
            })
        }
    }

    @ViewBuilder func speakerItems(_ s: Speaker) -> some View {
        Button("Rename…") { rename(s) }
        Menu("Merge Into") { ForEach(SpeakerMenu.mergeTargets(for: s, in: speakers)) { t in Button(t.shownName) { merge(s, into: t) } } }
    }

    func rename(_ s: Speaker) { renaming = s; newName = s.displayName ?? "" }

    func merge(_ source: Speaker, into target: Speaker) { apply { try $0.merge([source.id], into: target.id) } }

    func apply(_ make: (EditComposer) throws -> UserEdit) {
        guard let t = detail.transcript else { return }
        let composer = EditComposer(meetingID: detail.meeting.id, revision: t, existing: detail.edits)
        if let e = try? make(composer) { library.apply(e) }
    }
}

struct TranscriptRowView: View {
    let row: TranscriptRow
    /// First row of a same-speaker run: shows the disc and name; continuation rows leave the column blank.
    let showsSpeaker: Bool
    let playable: Bool
    let play: () -> Void
    /// Rename / merge / assign menu behind the disc and name (T38); nil shows them as plain text.
    var speakerMenu: (() -> AnyView)? = nil
    @Environment(\.showDetails) private var showDetails
    @Environment(\.textScale) private var scale
    @Environment(\.transcriptStyle) private var style
    @Environment(\.speakerColors) private var colors

    static let timeWidth: CGFloat = 60
    static let speakerWidth: CGFloat = 140

    var body: some View {
        if row.isGap, !showDetails {
            Rectangle().fill(Color.statusAttention.opacity(0.45)).frame(height: 1)
                .padding(.vertical, 3).frame(maxWidth: .infinity).contentShape(Rectangle())
                .help(TranscriptRows.gapDescription(row))
                .accessibilityElement().accessibilityLabel(TranscriptRows.gapDescription(row))
        } else if case .gap(let reason) = row.kind {
            Label("\(TranscriptRows.clock(row.start))–\(TranscriptRows.clock(row.end)) · \(reason)", systemImage: "waveform.slash")
                .appFont(.callout).foregroundStyle(Color.statusAttention)
                .accessibilityLabel("Gap from \(TranscriptRows.clock(row.start)) to \(TranscriptRows.clock(row.end)): \(reason)")
        } else if style == .bubbles {
            bubble
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(TranscriptRows.clock(row.start), action: play)
                    .buttonStyle(.plain).appFont(.caption, monospacedDigit: true).foregroundStyle(playable ? Color.link : .secondary)
                    .disabled(!playable).help(playable ? "Play from here" : "Playback unavailable")
                    .frame(width: Self.timeWidth * scale, alignment: .leading)
                speaker.frame(width: Self.speakerWidth * scale, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Every row, continuation rows included, names its speaker for VoiceOver.
                    Text(row.text).appFont(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("\(row.speakerLabel): \(row.text)")
                    badges.fixedSize()
                }
            }
        }
    }

    /// Bubbles (T37): the microphone (you) on the right in the accent tint, other speakers on the left in their colour,
    /// the name above the first bubble of a run, time and flags in a caption beside each bubble.
    @ViewBuilder var bubble: some View {
        let mine = row.source == .microphone
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if showsSpeaker {
                withSpeakerMenu {
                    HStack(spacing: AppStyle.half) {
                        SpeakerDisc(assignment: row.assignment, name: row.speakerLabel, size: 14 * scale)
                        Text(row.speakerLabel.replacingOccurrences(of: " (overlapping)", with: "")).appFont(.caption, weight: .semibold)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.top, AppStyle.half)
            }
            HStack(alignment: .bottom, spacing: AppStyle.half + 2) {
                if mine { bubbleCaption }
                Text(row.text).appFont(.body).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background((mine ? Color.accentColor : SpeakerDisc.color(row.assignment, colors)).opacity(0.16), in: .rect(cornerRadius: 12))
                    .accessibilityLabel("\(row.speakerLabel): \(row.text)")
                if !mine { bubbleCaption }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 96 * scale)
        .padding(.vertical, 1)
    }

    /// The disc and name as a borderless menu button when actions are available, else plain (tooltip either way).
    @ViewBuilder func withSpeakerMenu<L: View>(@ViewBuilder _ label: () -> L) -> some View {
        if let speakerMenu {
            Menu { speakerMenu() } label: { label() }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .help("\(row.speakerLabel): rename, merge, or assign this line to someone else")
                .accessibilityLabel("Speaker \(row.speakerLabel)")
                .accessibilityHint("Rename, merge, or assign this line")
        } else {
            label().help(row.speakerLabel).accessibilityHidden(true)
        }
    }

    var bubbleCaption: some View {
        HStack(spacing: AppStyle.half) {
            Button(TranscriptRows.clock(row.start), action: play)
                .buttonStyle(.plain).appFont(.caption2, monospacedDigit: true).foregroundStyle(playable ? Color.link : .secondary)
                .disabled(!playable).help(playable ? "Play from here" : "Playback unavailable")
            badges
        }
        .fixedSize()
        .padding(.bottom, 4)
    }

    @ViewBuilder var speaker: some View {
        if showsSpeaker {
            withSpeakerMenu {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SpeakerDisc(assignment: row.assignment, name: row.speakerLabel, size: 16 * scale).alignmentGuide(.firstTextBaseline) { $0.height * 0.75 }
                    // Overlap shows as the group disc and the overlap flag, so the column drops the "(overlapping)" suffix.
                    Text(row.speakerLabel.replacingOccurrences(of: " (overlapping)", with: "")).appFont(.body, weight: .semibold).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(row.assignment == .unknown ? .secondary : .primary)
                }
            }
        } else {
            Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }

    @ViewBuilder var badges: some View {
        HStack(spacing: 6) {
            if showDetails {
                Text(row.source == .microphone ? "MIC" : "SYS").appFont(.caption2, weight: .bold).padding(.horizontal, 4)
                    .background(.quaternary, in: .rect(cornerRadius: 3)).help(row.source == .microphone ? "Your microphone" : "System audio")
            }
            if row.flags.contains(.overlap) { flag("overlap", "person.2.wave.2", "Several people spoke at once") }
            if row.flags.contains(.uncertainSpeaker) { flag("speaker uncertain", "questionmark.circle", "Speaker attribution is uncertain") }
            if row.flags.contains(.probableEcho) { flag("echo?", "speaker.wave.2", "Probably your speakers picked up by the mic; kept, not deleted") }
            if row.flags.contains(.questionableText) { flag("check text", "exclamationmark.triangle", "Speech recognition may have garbled this") }
            if row.flags.contains(.corrected) { flag("edited", "pencil", "You corrected this text") }
        }
    }

    /// Icon and caption with Details on; icon only (same tooltip, caption as the VoiceOver label) in skim mode.
    @ViewBuilder func flag(_ text: String, _ icon: String, _ help: String) -> some View {
        if showDetails {
            Label(text, systemImage: icon).appFont(.caption2).foregroundStyle(Color.statusAttention).help(help).labelStyle(.titleAndIcon)
        } else {
            Label(text, systemImage: icon).appFont(.caption2).foregroundStyle(Color.statusAttention).help(help).labelStyle(.iconOnly)
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
                    Text("Speakers").appFont(.caption).foregroundStyle(.secondary)
                    ForEach(speakers) { s in
                        Menu {
                            Button("Rename…") { rename(s) }
                            Menu("Merge Into") { ForEach(SpeakerMenu.mergeTargets(for: s, in: speakers)) { t in Button(t.shownName) { merge(s, t) } } }
                        } label: { Text(s.shownName) }
                        .menuStyle(.button).controlSize(.small).fixedSize()
                    }
                }
                .padding(.horizontal, AppStyle.grid).padding(.vertical, AppStyle.half)
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
                Label(reason, systemImage: "speaker.slash").appFont(.caption).foregroundStyle(.secondary)
            } else {
                Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                    .keyboardShortcut(.space, modifiers: []).help(playback.isPlaying ? "Pause (Space)" : "Play (Space)")
                Text(TranscriptRows.clock(SessionTime(nanoseconds: Int64(playback.position * 1e9)))).appFont(.caption, monospacedDigit: true)
                if let e = playback.error { Text(e).appFont(.caption).foregroundStyle(Color.statusFailed) }
            }
        }
        .padding(.horizontal, AppStyle.grid).padding(.vertical, 2)
    }
}
