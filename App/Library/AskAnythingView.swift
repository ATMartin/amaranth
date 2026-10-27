import SwiftUI
import Domain
import Presentation
import Storage

/// “Ask anything” (T52): a field pinned to the bottom of the detail column. Return searches (local FTS for now; the model
/// answers in T54) and shows the results panel above the field; ↑/↓ pick a hit, Return opens it, Esc closes the panel.
/// ⌘K focuses the field with All meetings as the scope. Replaces the sidebar search field.
struct AskAnythingBar: View {
    @Environment(LibraryModel.self) private var library
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var library = library
        HStack(spacing: AppStyle.grid) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            TextField("Ask anything", text: $library.query, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .appFont(.body)
                .focused($focused)
                .onSubmit { library.submitAsk() }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) {
                    guard library.askPanelOpen else { return .ignored }
                    library.closeAskPanel()
                    return .handled
                }
                .accessibilityLabel("Ask anything")
                .accessibilityHint("Searches \(scopeDescription). Press Return to search.")
            if !focused && library.query.isEmpty {
                Text("⌘K").appFont(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, AppStyle.grid + 4).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25), lineWidth: focused ? 1.5 : 0.5))
        .padding(.horizontal, AppStyle.double).padding(.vertical, AppStyle.grid)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: library.askFocusRequest) { _, _ in focused = true }
    }

    var prompt: String {
        AskResults.effectiveScope(library.askScope, meeting: library.selection) == nil ? "Ask anything across all meetings" : "Ask anything about this meeting"
    }

    var scopeDescription: String {
        AskResults.effectiveScope(library.askScope, meeting: library.selection) == nil ? "all meetings" : "this meeting"
    }

    func move(_ delta: Int) -> KeyPress.Result {
        guard library.askPanelOpen, !library.hits.isEmpty else { return .ignored }
        library.moveAskSelection(by: delta)
        return .handled
    }
}

/// The results panel above the field: a scope switch, then hits grouped by meeting with highlighted snippets.
struct AskResultsPanel: View {
    @Environment(LibraryModel.self) private var library
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        @Bindable var library = library
        let groups = AskResults.grouped(library.hits)
        let thisMeetingAvailable = library.selection != nil
        VStack(spacing: 0) {
            HStack(spacing: AppStyle.grid) {
                Picker("Scope", selection: $library.askScope) {
                    ForEach(AskScope.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(!thisMeetingAvailable)
                .help(thisMeetingAvailable ? "Search this meeting or all meetings" : "Open a meeting to search just that meeting")
                Spacer()
                Text(countLabel(groups)).appFont(.caption).foregroundStyle(.secondary)
                Button { library.closeAskPanel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Close (Esc)").accessibilityLabel("Close results")
            }
            .padding(.horizontal, AppStyle.grid + 4).padding(.vertical, AppStyle.grid)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    results(groups)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, 44), maxHeight))
                .onChange(of: library.askSelection) { _, i in if let i { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i) } } }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, AppStyle.double).padding(.bottom, AppStyle.half)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search results")
    }

    @ViewBuilder func results(_ groups: [AskResults.Group]) -> some View {
        if groups.isEmpty {
            HStack {
                Text(library.askScope == .thisMeeting && library.selection != nil ? "No matches in this meeting." : "No matches.")
                    .foregroundStyle(.secondary)
                if library.askScope == .thisMeeting, library.selection != nil {
                    Button("Search All Meetings") { library.askScope = .allMeetings }.buttonStyle(.link)
                }
                Spacer()
            }
            .appFont(.callout)
            .padding(AppStyle.grid + 4)
        } else {
            VStack(alignment: .leading, spacing: 0) {   // at most 50 hits: no need for lazy rows
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
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.grid) {
            Text(group.title).appFont(.caption, weight: .bold).lineLimit(1)
            if let date = library.items.first(where: { $0.id == group.meetingID })?.createdAt {
                Text(date.formatted(date: .abbreviated, time: .shortened)).appFont(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, AppStyle.grid + 4).padding(.top, AppStyle.grid).padding(.bottom, 2)
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

/// One hit: where it matched (a transcript time, notes, your notes or the title) and the snippet with the match in bold.
struct AskHitRow: View {
    let hit: SearchHit
    var selected = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppStyle.grid) {
            Text(AskResults.kindLabel(hit)).appFont(.caption, monospacedDigit: true).foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 64, alignment: .leading)
            Text(SearchSnippet.highlighted(hit.snippet)).appFont(.callout).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppStyle.grid + 4).padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
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
