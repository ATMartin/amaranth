import SwiftUI
import Domain
import Presentation
import Storage

/// The Ask pane (T52/T54; a right-hand inspector since the Inner Circle handoff): the scope switch at the top, the
/// answer and the matches in the middle, the field at the bottom. Return searches and asks the local model; ↑/↓ pick a
/// match, Return opens it (the results stay, so the next one is a click away), × or Esc clears the question and results
/// and leaves the cursor in the field. ⌘K opens the pane and
/// focuses the field with All meetings as the scope.
struct AskPane: View {
    @Environment(LibraryModel.self) private var library
    @Environment(ModelSetupModel.self) private var models

    var body: some View {
        @Bindable var library = library
        let groups = AskResults.grouped(library.hits)
        let thisMeetingAvailable = library.selection != nil
        // Ask always searches by meaning: without the models and the search model the pane is shown dimmed and inert,
        // with what's missing and the way to Settings → Models on top (checking takes milliseconds at launch: no flash).
        let usable = models.askReady || models.status == .checking
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppStyle.grid) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(text: "Ask")
                    Spacer()
                    if library.askPanelOpen {
                        Text(countLabel(groups)).appFont(.caption2).foregroundStyle(Color.brandSecondary)
                        Button { library.clearAsk() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(Color.brandSecondary)
                            .help("Clear the question and results (Esc)").accessibilityLabel("Clear")
                    }
                }
                // T42: “This folder” appears while the sidebar shows a folder.
                BrandSegmented(options: AskScope.options(folderShown: library.filteredFolder != nil, meetingOpen: thisMeetingAvailable), selection: $library.askScope) { $0.label(short: library.filteredFolder != nil) }
                    .accessibilityLabel("Scope")
                .disabled(!usable || !thisMeetingAvailable && library.filteredFolder == nil)
                .help(library.filteredFolder.map { "Ask about this meeting, the folder “\($0.name)” or all meetings" }
                      ?? (thisMeetingAvailable ? "Ask about this meeting or all meetings" : "Open a meeting to ask about just that meeting"))
            }
            .padding(.horizontal, AppStyle.double).padding(.top, AppStyle.grid + 4).padding(.bottom, AppStyle.grid + 2)
            .opacity(usable ? 1 : AskUnavailableNotice.dimmed)
            Hairline(opacity: 0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !usable {
                            AskUnavailableNotice()
                            intro.opacity(AskUnavailableNotice.dimmed).accessibilityHidden(true)
                        } else if library.askPanelOpen {
                            SearchModelNotice()
                            if let answers = library.answers, answers.phase != .idle {
                                AnswerSection(answers: answers)
                                Hairline(opacity: 0.35).padding(.horizontal, AppStyle.double)
                            }
                            results(groups)
                        } else {
                            SearchModelNotice()
                            intro
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: library.askSelection) { _, i in if let i { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i) } } }
            }
            Hairline(opacity: 0.4)
            AskField()
                .disabled(!usable)
                .opacity(usable ? 1 : AskUnavailableNotice.dimmed)
        }
        .background(Color.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask")
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: AppStyle.grid + 2) {
            Text("Ask about your meetings.").appFont(.display).foregroundStyle(Color.brandText).fixedSize(horizontal: false, vertical: true)
            Text("Find an answer, then follow it back to the line it came from. Answers come from the model on this Mac.")
                .appFont(.callout).italic().foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppStyle.double).padding(.top, AppStyle.double)
    }

    @ViewBuilder func results(_ groups: [AskResults.Group]) -> some View {
        if groups.isEmpty {
            HStack {
                Text(library.askScope == .thisMeeting && library.selection != nil ? "No matches in this meeting."
                     : library.askFolder != nil ? "No matches in this folder." : "No matches.")
                    .foregroundStyle(Color.brandSecondary)
                if library.askScope == .thisMeeting && library.selection != nil || library.askFolder != nil {
                    Button("Search All Meetings") { library.askScope = .allMeetings }.buttonStyle(.brandLink)
                }
                Spacer()
            }
            .appFont(.callout)
            .padding(AppStyle.double)
        } else {
            VStack(alignment: .leading, spacing: 0) {   // at most 50 hits: no need for lazy rows
                if library.answers.map({ $0.phase != .idle }) ?? false {
                    // T115: the keyword lookup stays available, labeled for what it is (not the answer's evidence).
                    Eyebrow(text: "Exact word matches").padding(.horizontal, AppStyle.double).padding(.top, AppStyle.grid)
                }
                let offsets = groupOffsets(groups)
                ForEach(Array(groups.enumerated()), id: \.offset) { gi, group in
                    groupHeader(group)
                    ForEach(Array(group.hits.enumerated()), id: \.offset) { hi, hit in
                        let index = offsets[gi] + hi
                        Button { library.open(hit) } label: {
                            AskHitRow(hit: hit, selected: library.askSelection == index)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
            }
            .padding(.vertical, AppStyle.half)
        }
    }

    func groupHeader(_ group: AskResults.Group) -> some View {
        let item = library.items.first { $0.id == group.meetingID }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: AppStyle.grid) {
                Text(group.title).appFont(.caption, weight: .bold).lineLimit(1)
                if let date = item?.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).appFont(.caption2).foregroundStyle(Color.brandSecondary)
                }
                Spacer()
            }
            // T40: the folder of a filed meeting, under its title.
            if let folder = library.folderName(item?.folderID) {
                Label(folder, systemImage: "folder").appFont(.caption2).foregroundStyle(Color.brandSecondary).lineLimit(1)
                    .accessibilityLabel("In folder \(folder)")
            }
        }
        .padding(.horizontal, AppStyle.double).padding(.top, AppStyle.grid + 2).padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }

    func groupOffsets(_ groups: [AskResults.Group]) -> [Int] {
        var out: [Int] = [], n = 0
        for g in groups { out.append(n); n += g.hits.count }
        return out
    }

    func countLabel(_ groups: [AskResults.Group]) -> String {
        let n = library.hits.count
        if n == 0 { return "" }
        let hits = n == 1 ? "1 match" : "\(n) matches"
        return groups.count > 1 ? "\(hits) in \(groups.count) meetings" : hits
    }
}

/// The ask field at the bottom of the pane: Return asks, ↑/↓ move through the matches, Esc clears the question and them.
struct AskField: View {
    @Environment(LibraryModel.self) private var library
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var library = library
        HStack(spacing: AppStyle.grid) {
            TextField("Ask anything", text: $library.query, prompt: Text(prompt).foregroundStyle(Color.brandSecondary), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .appFont(.callout)
                .focused($focused)
                .onSubmit { library.submitAsk() }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) {
                    guard library.askPanelOpen || !library.query.isEmpty else { return .ignored }
                    library.clearAsk()
                    return .handled
                }
                .accessibilityLabel("Ask anything")
                .accessibilityHint("Searches \(scopeDescription). Press Return to ask.")
            if !focused && library.query.isEmpty {
                Text("⌘K").appFont(.caption2).foregroundStyle(Color.brandSecondary).accessibilityHidden(true)
            } else {
                Button("Ask") { library.submitAsk() }.buttonStyle(.plain).appFont(.callout, weight: .medium).foregroundStyle(Color.brandAccent)
                    .disabled(library.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, AppStyle.grid + 4).padding(.vertical, AppStyle.grid + 1)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.brandAccent : Color.controlBorder, lineWidth: focused ? 1.5 : 1))
        .padding(AppStyle.grid + 4)
        .onChange(of: library.askFocusRequest) { _, _ in takeFocus() }
        // ⌘K with the pane hidden: the field only exists once the pane opens.
        .onAppear { if library.askFocusPending { Task { @MainActor in takeFocus() } } }
    }

    func takeFocus() {
        focused = true
        library.askFocusPending = false
    }

    var prompt: String {
        if let f = library.askFolder.flatMap({ library.folderName($0) }) { return "Ask about \(f)…" }
        return AskResults.effectiveScope(library.askScope, meeting: library.selection) == nil ? "Ask across all meetings…" : "Ask about this meeting…"
    }

    var scopeDescription: String {
        if let f = library.askFolder.flatMap({ library.folderName($0) }) { return "the folder \(f)" }
        return AskResults.effectiveScope(library.askScope, meeting: library.selection) == nil ? "all meetings" : "this meeting"
    }

    func move(_ delta: Int) -> KeyPress.Result {
        guard library.askPanelOpen, !library.hits.isEmpty else { return .ignored }
        library.moveAskSelection(by: delta)
        return .handled
    }
}

/// One hit: where it matched (a transcript time, notes, your notes or the title) and the snippet with the match in bold.
struct AskHitRow: View {
    let hit: SearchHit
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(AskResults.kindLabel(hit)).appFont(.caption2, monospacedDigit: true).foregroundStyle(selected ? Color.brandText : Color.link)
            Text(SearchSnippet.highlighted(hit.snippet)).appFont(.caption).foregroundStyle(Color.brandText).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppStyle.double).padding(.vertical, 6)
        .background(selected ? Color.selection : .clear)
        .overlay(alignment: .leading) { if selected { Color.brandAccent.frame(width: 3) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens the meeting at this match")
    }
}

enum SearchSnippet {
    /// Snippet with the `[match]` markers rendered bold.
    static func highlighted(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        for part in snippet.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "[" || $0 == "]" }) {
            var a = AttributedString(String(part))
            if bold { a.inlinePresentationIntent = .stronglyEmphasized }
            out += a
            bold.toggle()
        }
        return out
    }
}

/// The model's answer above the matches (T54): the question, the answer streaming in, citation chips that jump to the
/// cited line, and a caption that it comes from the local model.
struct AnswerSection: View {
    let answers: AnswerModel
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.grid) {
            // T55: the conversation so far (follow-ups are answered with it as context), oldest first, dimmed.
            let earlier = answers.history.filter { $0.question != answers.question }
            if !earlier.isEmpty {
                VStack(alignment: .leading, spacing: AppStyle.half) {
                    ForEach(Array(earlier.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(turn.question).appFont(.caption, weight: .semibold)
                            Text(turn.answer).appFont(.caption).lineLimit(2)
                        }
                        .foregroundStyle(Color.brandSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Earlier in this conversation")
            }
            HStack(alignment: .firstTextBaseline, spacing: AppStyle.half) {
                Image(systemName: "sparkles").foregroundStyle(Color.brandAccent).accessibilityHidden(true)
                Text(answers.question).appFont(.callout, weight: .semibold).lineLimit(2)
                Spacer(minLength: 0)
            }
            switch answers.phase {
            case .working(let stage):
                AskLoadingView(stage: stage, waitingReason: nil, started: answers.submittedAt) { answers.cancel() }
            case .waiting(let reason):
                AskLoadingView(stage: .preparing, waitingReason: reason, started: answers.submittedAt) { answers.cancel() }
            case .streaming:
                Text(answers.text).appFont(.callout).fixedSize(horizontal: false, vertical: true).foregroundStyle(Color.brandText)
                HStack(spacing: AppStyle.half) {
                    SeedRing(phase: 0, pulse: 0.5).frame(width: 12, height: 12).accessibilityHidden(true)
                    Text("Still writing — checking it against the sources next").appFont(.caption2).foregroundStyle(Color.brandSecondary)
                }
            case .done:
                Text(answers.text).appFont(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(answers.response?.refused == true ? Color.brandSecondary : Color.brandText)
                if !answers.citedPassages.isEmpty {
                    FlowChips(passages: answers.citedPassages, acrossMeetings: answers.acrossMeetings) { library.open(citation: $0) }
                }
                AnswerNotes(notes: answers.notes)
                if answers.response?.refused == false {
                    Text(caption).appFont(.caption2).foregroundStyle(Color.brandSecondary)
                }
                if !answers.passages.isEmpty { PassagesRead(passages: answers.passages, cited: Set(answers.response?.citations ?? [])) { library.open(citation: $0) } }
            case .clarification(let t):
                Label { Text(t).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "questionmark.bubble").foregroundStyle(Color.brandAccent) }
                    .appFont(.callout)
                AnswerNotes(notes: answers.notes)
            case .noEvidence(let t):
                Text(t).appFont(.callout).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
                AnswerNotes(notes: answers.notes)
                Text("Not finding it in the meetings searched doesn't mean it was never said.").appFont(.caption2).foregroundStyle(Color.brandSecondary)
            case .timedOut, .stale, .unavailable, .failed:
                Label { Text(terminalText).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: terminalIcon) }
                    .appFont(.callout).foregroundStyle(Color.brandSecondary)
                if answers.canRetry { Button("Retry") { answers.retry() }.buttonStyle(.brandLink).appFont(.callout) }
            case .idle: EmptyView()
            }
        }
        .padding(.horizontal, AppStyle.double).padding(.vertical, AppStyle.grid + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer")
    }

    var terminalText: String {
        switch answers.phase {
        case .timedOut: "That took longer than 15 seconds, so it stopped rather than show an unchecked answer."
        case .stale: "The meetings this answer used changed while it was being written, so it was withheld. Ask again for an answer from the current text."
        case .unavailable(let r), .failed(let r): r
        default: ""
        }
    }

    var terminalIcon: String {
        switch answers.phase { case .timedOut: "clock"; case .stale: "arrow.triangle.2.circlepath"; case .unavailable: "info.circle"; default: "exclamationmark.triangle" }
    }

    var caption: String {
        let base = "This answer is from the local model and may be wrong."
        return answers.response?.confidence == .low ? base + " It is unsure about part of it: check the cited lines." : base
    }
}

/// Citation chips: “12:34” within a meeting, “Leesa 1:1 · 12:34” across meetings. Click to open the cited line.
struct FlowChips: View {
    let passages: [Passage]
    let acrossMeetings: Bool
    let open: (Passage) -> Void

    var body: some View {
        // Chips wrap onto more lines rather than truncating.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppStyle.half) { chips }
            VStack(alignment: .leading, spacing: AppStyle.half) { chips }
        }
    }

    @ViewBuilder var chips: some View {
        ForEach(Array(passages.enumerated()), id: \.offset) { _, p in
            CitationChip(label: AskPassages.label(p, acrossMeetings: acrossMeetings), notes: p.source != .transcript) { open(p) }
        }
    }
}

/// A source link under an answer ("12:34 ↗", "Leesa 1:1 · 12:34 ↗"): accent, underlined.
struct CitationChip: View {
    let label: String
    let notes: Bool
    let action: () -> Void

    var body: some View {
        Button(label, action: action)
            .buttonStyle(SourceLinkStyle())
            .help(notes ? "Open the note this came from" : "Show this line in the transcript")
            .accessibilityLabel("Source: \(label)")
    }
}

/// What was searched and its limits, under an answer (T115).
struct AnswerNotes: View {
    let notes: [String]
    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                    Label { Text(n).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
                        .labelStyle(.titleAndIcon).appFont(.caption2).foregroundStyle(Color.brandSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("About this search: " + notes.joined(separator: " "))
        }
    }
}

/// The passages the answer was written from (T115), collapsed: meeting · time and the lines that matched. Cited ones
/// are marked. Click opens the line.
struct PassagesRead: View {
    let passages: [Passage]
    let cited: Set<Int>
    let open: (Passage) -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: AppStyle.half + 2) {
                ForEach(Array(passages.enumerated()), id: \.offset) { i, p in
                    Button { open(p) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: AppStyle.half) {
                                Text(AskPassages.label(p, acrossMeetings: true, withDate: true)).appFont(.caption2, monospacedDigit: true).foregroundStyle(Color.link)
                                if cited.contains(i + 1) { Text("cited").appFont(.caption2, weight: .semibold).foregroundStyle(Color.sage) }
                            }
                            Text((p.lines.filter(\.matched).isEmpty ? p.lines : p.lines.filter(\.matched)).prefix(2)
                                .map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: " "))
                                .appFont(.caption).foregroundStyle(Color.brandText).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the meeting at this passage")
                }
            }
            .padding(.top, AppStyle.half)
        } label: {
            Text("Passages read (\(passages.count))").appFont(.caption, weight: .medium).foregroundStyle(Color.brandSecondary)
        }
    }
}

/// Indexing progress in the Ask pane (T115): the meetings still being prepared for search. Nothing when ready.
struct SearchModelNotice: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        if let i = library.indexer, i.coverage.encoderAvailable || i.state == .indexing, i.coverage.meetingsInScope > 0, !i.coverage.complete {
            VStack(alignment: .leading, spacing: AppStyle.half) {
                Label { Text("Getting meetings ready for search: \(i.coverage.meetingsIndexed) of \(i.coverage.meetingsInScope)\(pauseText(i.state)).").fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "circle.dashed").foregroundStyle(Color.sage) }
                    .appFont(.caption).foregroundStyle(Color.brandSecondary)
            }
            .padding(.horizontal, AppStyle.double).padding(.vertical, AppStyle.grid)
            .accessibilityElement(children: .combine)
        }
    }

    func pauseText(_ s: ContextIndexer.State) -> String {
        if case .paused(let r) = s { return " (\(r.lowercased()))" }
        return ""
    }
}

/// Why Ask can't be used yet, on top of the dimmed pane: no local models (a new install), the search model missing
/// (an update from before spec 0010) or installing. Setup lives in Settings → Models (T77), like the sidebar footer.
struct AskUnavailableNotice: View {
    /// The opacity of the inert pane behind the notice.
    static let dimmed = 0.4
    @Environment(ModelSetupModel.self) private var models
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: AppStyle.grid) {
            Label { Text(title).appFont(.callout, weight: .semibold).foregroundStyle(Color.brandText) }
                icon: { Image(systemName: installing ? "arrow.down.circle" : "exclamationmark.triangle.fill").foregroundStyle(installing ? Color.brandSecondary : Color.statusAttention) }
            Text(message).appFont(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
            Button(installing ? "Show Progress in Settings" : "Open Settings → Models") { openSettings(.models) }
                .buttonStyle(.brandLink).appFont(.caption)
        }
        .padding(AppStyle.grid + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.controlBorder, lineWidth: 1))
        .padding(.horizontal, AppStyle.double).padding(.top, AppStyle.double)
        .accessibilityElement(children: .contain)   // the Settings button stays its own control
    }

    var installing: Bool { if case .installing = models.status { true } else { false } }

    var title: String {
        if case .installing(let p) = models.status {
            return "Installing models… \(Int(100 * Double(p.bytesDone) / Double(max(1, p.bytesTotal))))%"
        }
        return models.searchModelMissing ? "Ask needs the search model" : "Ask needs the local models"
    }

    var message: String {
        if installing { return "Ask is ready as soon as the install finishes." }
        if models.searchModelMissing {
            return "Ask finds what was meant in your meetings, not just the words used, with a search model that runs on this Mac (\(ModelSetupModel.gb(models.pendingDownloadBytes)) download; the models you have are reused). Recording, transcripts and notes keep working."
        }
        return "Ask answers from your meetings with models that run on this Mac. Install them in Settings → Models. Recording works without them."
    }
}
