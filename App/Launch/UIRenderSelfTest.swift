import AppKit
import SwiftUI
import Domain
import DomainFixtures
import Storage
import Presentation
import Export

/// `Amaranth --self-test ui-render --self-test-output <dir>`: builds the real views over a temporary store (fixture
/// meetings plus a synthetic two-hour meeting), lays them out offscreen, writes PNGs, and reports layout/render times.
/// No audio, no permissions, and nothing touches the user's library. Every screen renders in light and in dark (T43),
/// into `<dir>/light/` and `<dir>/dark/`.
enum UIRenderSelfTest {
    @MainActor static func run(outputDirectory: URL?, textSize: TextSize = .default) async -> Bool {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "amaranth-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = outputDirectory ?? root.appending(path: "png")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let store = try? MeetingStore(root: root) else { SelfTest.log(["step": "store", "ok": "false"]); return false }
        do {
            for f in Fixtures.all { try persistFixture(f, store) }
            try persistLongMeeting(store)
            // T50: one meeting with people so the header shows names; the others show "Add people…".
            try store.setPeople(["Dana Whitfield", "Ravi Patel", "Mei Chen", "Tomás Ortega"].map { Person(name: $0) }, for: MeetingID("ui-long"))
            // T40: two folders and unfiled meetings: Acme holds two meetings, Hiring one, the rest are unfiled.
            let acme = try store.createFolder(name: "Acme"), hiring = try store.createFolder(name: "Hiring")
            try store.moveMeeting(MeetingID("ui-long"), to: acme.id)
            try store.moveMeeting(MeetingID("fx-two-source"), to: acme.id)
            try store.moveMeeting(MeetingID("fx-paused"), to: hiring.id)
        } catch { SelfTest.log(["step": "fixtures", "error": "\(error)"]); return false }
        var ok = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            SelfTest.log(["step": "appearance", "appearance": name])
            let dir = out.appending(path: name)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if await !render(store: store, out: dir, textSize: textSize, appearance: NSAppearance(named: appearance)!) { ok = false }
        }
        menuBarIconProofs(out: out)
        SelfTest.log(["step": "output", "directory": out.path])
        return ok
    }

    /// Menu bar glyph proofs at true 1x and 2x pixels (`menu-bar-icon-1x.png`, `-2x.png`): one column per state, one row
    /// per bar: light, dark, and the template colour over a light and a dark wallpaper tint (how macOS draws it on a
    /// translucent bar). The glyph is tinted the way the menu bar tints a template image.
    @MainActor static func menuBarIconProofs(out: URL) {
        let bars: [(NSColor, NSColor)] = [
            (NSColor(white: 0.96, alpha: 1), .black), (NSColor(white: 0.12, alpha: 1), .white),
            (NSColor(srgbRed: 0.80, green: 0.86, blue: 0.93, alpha: 1), NSColor(white: 0, alpha: 0.85)),
            (NSColor(srgbRed: 0.22, green: 0.18, blue: 0.30, alpha: 1), NSColor(white: 1, alpha: 0.9)),
        ]
        let states = MenuBarIcon.State.allCases
        let cell = NSSize(width: 40, height: 24)
        for scale in [1, 2] {
            let size = NSSize(width: cell.width * CGFloat(states.count), height: cell.height * CGFloat(bars.count))
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for (row, bar) in bars.enumerated() {
                let y = size.height - cell.height * CGFloat(row + 1)
                bar.0.setFill(); NSRect(x: 0, y: y, width: size.width, height: cell.height).fill()
                for (col, state) in states.enumerated() {
                    let icon = MenuBarIcon.image(state)
                    let tinted = NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r); bar.1.set(); r.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: NSRect(x: cell.width * CGFloat(col) + 4, y: y + (cell.height - icon.size.height) / 2,
                                           width: icon.size.width, height: icon.size.height))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "menu-bar-icon-\(scale)x.png"))
        }
        SelfTest.log(["step": "menu-bar-icon", "states": states.map(\.accessibilityLabel).joined(separator: " | ")])
    }

    @MainActor static func render(store: MeetingStore, out: URL, textSize: TextSize, appearance: NSAppearance) async -> Bool {
        let worker = WorkerClient()
        let models = ModelSetupModel()
        let recorder = RecorderModel(store: store, recover: false)
        // The sidebar's folder filter is a user preference: start from All meetings and put the user's back afterwards.
        let savedFilter = UserDefaults.standard.object(forKey: LibraryModel.folderFilterKey)
        UserDefaults.standard.removeObject(forKey: LibraryModel.folderFilterKey)
        defer { UserDefaults.standard.set(savedFilter, forKey: LibraryModel.folderFilterKey) }
        let library = LibraryModel(store: store)
        let playback = PlaybackModel()
        let live = LiveTextModel(client: worker)
        // A fake calendar (T57): the header chip reads it; the user's calendars are never touched.
        let calendarSource = FakeCalendarSource(status: .fullAccess, events: Self.calendarEvents(on: Date()))
        let calendar = CalendarModel(source: calendarSource)
        UserDefaults.standard.set(true, forKey: "onboarded")
        // Editors expanded (T24) without touching the user's own expansion preferences.
        // Fixed names: cfprefsd may write an empty plist for a suite after it's removed, so reuse two instead of leaving one
        // per run in ~/Library/Preferences. Each run starts them empty.
        let expandedSuite = "amaranth-ui-render-expanded"
        UserDefaults.standard.removePersistentDomain(forName: expandedSuite)
        let expanded = UserDefaults(suiteName: expandedSuite)!
        expanded.set(true, forKey: "notesUserNotesExpanded"); expanded.set(true, forKey: "notesScratchpadExpanded")
        let collapsedSuite = "amaranth-ui-render-collapsed"
        UserDefaults.standard.removePersistentDomain(forName: collapsedSuite)
        let collapsed = UserDefaults(suiteName: collapsedSuite)!   // empty: every preference at its default
        defer {
            for s in [expandedSuite, collapsedSuite] {
                UserDefaults.standard.removePersistentDomain(forName: s)
            }
        }
        var ok = true
        func makeView<V: View>(_ v: V, size: CGSize) -> NSView {
            let view = NSHostingView(rootView: v.textSize(textSize).environment(worker).environment(models).environment(recorder)
                .environment(library).environment(playback).environment(live).environment(calendar).frame(width: size.width, height: size.height)
                .background(Color.surface))
            // Offscreen windows don't draw vibrancy; force an opaque, fixed appearance so captures are readable.
            view.appearance = appearance
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = appearance
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
            window.contentView = view
            return view
        }
        func capture(_ view: NSView, _ name: String) {
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(name).png"))
        }
        func host<V: View>(_ v: V, _ name: String, size: CGSize) async -> Double {
            let view = makeView(v, size: size)
            let t0 = ContinuousClock.now
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))   // let async loads and List cells settle
            view.layoutSubtreeIfNeeded()
            capture(view, name)
            let d = ContinuousClock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 - 0.6
        }
        // Library + each fixture meeting's detail views.
        library.reload()
        try? await Task.sleep(for: .milliseconds(500))
        SelfTest.log(["step": "library", "meetings": "\(library.items.count)"])
        for item in library.items {
            library.selection = item.id
            for _ in 0..<40 where library.detail?.meeting.id != item.id { try? await Task.sleep(for: .milliseconds(50)) }
            guard let d = library.detail else { ok = false; SelfTest.log(["step": "detail", "meeting": item.title, "ok": "false"]); continue }
            let name = item.title.replacingOccurrences(of: " ", with: "-")
            let tMain = await host(MainView(), "main-\(name)", size: CGSize(width: 1200, height: 760))
            let tTranscript = await host(TranscriptPane(detail: d).environment(\.showDetails, false), "transcript-\(name)", size: CGSize(width: 900, height: 700))
            let tTranscriptDetails = await host(TranscriptPane(detail: d).environment(\.showDetails, true), "transcript-details-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(TranscriptPane(detail: d).environment(\.showDetails, false).environment(\.transcriptStyle, .bubbles), "transcript-bubbles-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(TranscriptPane(detail: d).environment(\.showDetails, true).environment(\.transcriptStyle, .bubbles), "transcript-bubbles-details-\(name)", size: CGSize(width: 900, height: 700))
            let tNotes = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).environment(\.showDetails, false).defaultAppStorage(collapsed), "notes-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).environment(\.showDetails, true).defaultAppStorage(collapsed), "notes-details-\(name)", size: CGSize(width: 900, height: 700))
            _ = await host(NotesPane(detail: d, notesModelInstalled: true, showTranscript: {}).defaultAppStorage(expanded), "notes-expanded-\(name)", size: CGSize(width: 900, height: 900))
            _ = await host(RecordingDetailsPane(detail: d), "recording-tab-\(name)", size: CGSize(width: 900, height: 600))
            SelfTest.log(["step": "render", "meeting": item.title, "rows": "\(d.rows.count)", "gaps": "\(d.rows.filter(\.isGap).count)",
                          "unknownSpeakerRows": "\(d.rows.filter { !$0.isGap && $0.assignment == .unknown }.count)",
                          "playback": d.playbackUnavailableReason ?? "available", "notes": "\(d.notesState(notesModelInstalled: true))",
                          "mainSeconds": String(format: "%.2f", tMain), "transcriptSeconds": String(format: "%.2f", tTranscript), "transcriptDetailsSeconds": String(format: "%.2f", tTranscriptDetails),
                          "notesSeconds": String(format: "%.2f", tNotes)])
            if d.rows.count > 1000, max(tTranscript, tTranscriptDetails) > 2.0 { ok = false }
        }
        // Evidence jump (T35): focusing a row mid-way through the two-hour meeting selects that row and scrolls it into
        // view, both when the pane is already showing (focus set later) and when it appears with the focus already set.
        if let long = library.items.first(where: { $0.id == MeetingID("ui-long") }) {
            library.selection = long.id
            for _ in 0..<40 where library.detail?.meeting.id != long.id { try? await Task.sleep(for: .milliseconds(50)) }
            if let d = library.detail {
                let shown = TranscriptRows.skim(d.rows)
                let speech = shown.filter { !$0.isGap }
                for style in TranscriptStyle.allCases {
                for (label, target, focusFirst) in [("while-shown", speech[speech.count / 2], false), ("on-appear", speech[speech.count / 3], true)] {
                    library.focusRowID = focusFirst ? target.id : nil
                    let view = NSHostingView(rootView: TranscriptPane(detail: d).environment(\.showDetails, false).textSize(textSize).environment(\.transcriptStyle, style).environment(library)
                        .environment(playback).frame(width: 900, height: 700).background(Color(nsColor: .windowBackgroundColor)))
                    view.appearance = appearance
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = appearance
                    window.contentView = view
                    try? await Task.sleep(for: .milliseconds(600))
                    if !focusFirst { library.focusRowID = target.id }
                    let table = Self.table(in: view)
                    let index = shown.firstIndex { $0.id == target.id } ?? -1
                    var visible = NSRange(location: 0, length: 0)
                    for _ in 0..<40 {
                        try? await Task.sleep(for: .milliseconds(50))
                        view.layoutSubtreeIfNeeded()
                        visible = table.map { $0.rows(in: $0.visibleRect) } ?? visible
                        if table?.selectedRow == index, NSLocationInRange(index, visible) { break }
                    }
                    let pass = table?.selectedRow == index && NSLocationInRange(index, visible)
                    SelfTest.log(["step": "evidence-jump", "style": style.rawValue, "case": label, "row": target.id, "index": "\(index)", "selected": "\(table?.selectedRow ?? -1)",
                                  "visible": "\(visible.location)..<\(visible.location + visible.length)", "ok": "\(pass)"])
                    if !pass { ok = false }
                    if pass, label == "while-shown", style == .columns {
                        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "transcript-evidence-jump.png"))
                    }
                    window.contentView = nil
                }
                }
                library.focusRowID = nil
            }
        }
        // Header chips in a narrow window (T50): the compact variant, nothing truncated.
        if library.items.contains(where: { $0.id == MeetingID("ui-long") }) {
            library.selection = MeetingID("ui-long")
            for _ in 0..<40 where library.detail?.meeting.id != MeetingID("ui-long") { try? await Task.sleep(for: .milliseconds(50)) }
            if let d = library.detail {
                _ = await host(MeetingDetailView(detail: d), "header-narrow", size: CGSize(width: 560, height: 200))
                // T79: the header with only ⋯ on the right, at the detail column's width in a 900 and an 1100 pt window
                // with the sidebar (180) and Ask (250) open; and the whole window at 900 pt.
                _ = await host(MeetingDetailView(detail: d), "header-900", size: CGSize(width: 470, height: 200))
                _ = await host(MeetingDetailView(detail: d), "header-1100", size: CGSize(width: 670, height: 200))
                _ = await host(MainView(), "main-900", size: CGSize(width: 900, height: 600))
                // The shared ⋯ / right-click menu's items, laid out flat: for the open meeting and for a card without a
                // transcript (Export disabled). Both come from MeetingActionsMenu, so they cannot drift apart.
                let card = library.items.first { !$0.hasTranscript } ?? library.items[0]
                _ = await host(HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) { Text("Header ⋯").bold(); MeetingActionsMenu(meeting: .init(d)) }
                    VStack(alignment: .leading, spacing: 6) { Text("Card: \(card.title)").bold(); MeetingActionsMenu(meeting: .init(card)) }
                }.padding(), "meeting-actions-menu", size: CGSize(width: 520, height: 260))
            }
        }
        // Header people editor (T50): with names and empty.
        _ = await host(PeopleEditor(people: ["Dana Whitfield", "Ravi Patel"].map { Person(name: $0) }, save: { _ in }, cancel: {}), "people-editor", size: CGSize(width: 290, height: 230))
        _ = await host(PeopleEditor(people: [], save: { _ in }, cancel: {}), "people-editor-empty", size: CGSize(width: 290, height: 230))
        // Calendar chip (T57): every state, each over its own fake calendar, then the popovers' contents.
        if let long = library.items.first(where: { $0.id == MeetingID("ui-long") }), let m = try? store.meeting(long.id) {
            let events = Self.calendarEvents(on: m.createdAt)
            calendarSource.setEvents(events)
            let linked = CalendarLinking.snapshot(events[0])
            var current = m; current.linkedEvent = linked
            var changed = m; changed.linkedEvent = LinkedEvent(identifier: linked.identifier, title: "Roadmap review", start: linked.start,
                                                              end: linked.end, calendarName: linked.calendarName)
            var missing = m; missing.linkedEvent = LinkedEvent(identifier: "deleted-event", title: "Vendor call", start: linked.start, end: linked.end)
            let cases: [(String, CalendarAuthorization, Meeting)] = [
                ("not determined", .notDetermined, m), ("full access, unlinked", .fullAccess, m), ("denied", .denied, m),
                ("write-only", .writeOnly, m), ("restricted", .restricted, m), ("linked", .fullAccess, current),
                ("changed since linking", .fullAccess, changed), ("no longer in calendar", .fullAccess, missing), ("linked, access off", .denied, current),
            ]
            _ = await host(VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(cases.enumerated()), id: \.offset) { _, c in
                    HStack {
                        Text(c.0).appFont(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                        CalendarLinkChip(meeting: c.2).environment(CalendarModel(source: FakeCalendarSource(status: c.1, events: events)))
                        Spacer()
                    }
                }
            }.padding(), "calendar-chip-states", size: CGSize(width: 520, height: 380))
            _ = await host(CalendarEventPicker(events: CalendarLinking.pickerEvents(events, recordedAt: m.createdAt), recordedAt: m.createdAt) { _ in },
                           "calendar-picker", size: CGSize(width: 340, height: 330))
            _ = await host(CalendarEventPicker(events: [], recordedAt: m.createdAt) { _ in }, "calendar-picker-empty", size: CGSize(width: 340, height: 180))
            for (name, status, also) in [("current", CalendarLinking.LiveStatus.current, [String]()), ("changed", .changed(events[0]), []),
                                         ("missing", .missing, []), ("also-linked", .current, ["Roadmap sync (dropped call)"])] {
                _ = await host(LinkedEventDetails(event: name == "changed" ? changed.linkedEvent! : linked, status: status, also: also, offersEventTitle: true,
                                                  update: {}, useTitle: {}, change: {}, unlink: {}), "calendar-linked-\(name)", size: CGSize(width: 340, height: 190))
            }
            _ = await host(LinkedEventDetails(event: linked, status: .unknown, also: [], offersEventTitle: false, access: .denied,
                                              update: {}, useTitle: {}, change: {}, unlink: {}), "calendar-linked-access-off", size: CGSize(width: 340, height: 170))
            for kind in [CalendarAccessMessage.Kind.off, .managed, .afterRecording] {
                _ = await host(CalendarAccessMessage(kind: kind), "calendar-access-\(kind)", size: CGSize(width: 320, height: 190))
            }
            // The real path: link from the chip's action, then the header shows the event; a second recording of the
            // same occurrence is "also linked"; the JSON export carries the link.
            library.selection = long.id
            for _ in 0..<40 where library.detail?.meeting.id != long.id { try? await Task.sleep(for: .milliseconds(50)) }
            library.link(long.id, to: events[0])
            for _ in 0..<40 where library.detail?.meeting.linkedEvent == nil { try? await Task.sleep(for: .milliseconds(50)) }
            if let other = library.items.first(where: { $0.id != long.id }) { library.link(other.id, to: events[0]) }
            try? await Task.sleep(for: .milliseconds(300))
            let also = (try? store.meetings(linkedTo: linked.identifier)) ?? []
            let exported = library.detail.flatMap { d in d.displayTranscript.map { ExportInput(meeting: d.meeting, transcript: $0, summary: d.summary, userNotes: d.userNotes, scratchpad: d.scratchpad) } }
                .flatMap { try? Exporter.json($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if let d = library.detail {
                _ = await host(MeetingDetailView(detail: d), "header-linked", size: CGSize(width: 900, height: 200))
                _ = await host(MeetingDetailView(detail: d), "header-linked-narrow", size: CGSize(width: 560, height: 200))
            }
            // T58: named attendees merged after the people already there, no room or unnamed guest, emails not kept.
            let people = library.detail?.meeting.people ?? []
            let peopleOK = people.prefix(4).map(\.name) == ["Dana Whitfield", "Ravi Patel", "Mei Chen", "Tomás Ortega"]
                && people.contains(Person(name: "Alex Martin", source: .calendar)) && !people.contains { $0.name == "Room 4B" }
                && library.detail?.meeting.linkedEvent?.unnamedAttendees == 1
            let pass = library.detail?.meeting.linkedEvent == linked && also.count == 2 && exported.contains("\"linkedEvent\"") && exported.contains(linked.title)
                && peopleOK
            SelfTest.log(["step": "calendar-link", "linked": library.detail?.meeting.linkedEvent?.title ?? "-", "alsoLinked": "\(also.count)",
                          "people": people.map { "\($0.name)(\($0.source.rawValue))" }.joined(separator: ", "), "peopleOK": "\(peopleOK)",
                          "jsonExportHasLink": "\(exported.contains("\"linkedEvent\""))", "ok": "\(pass)"])
            if let d = library.detail {
                _ = await host(PeopleEditor(people: d.meeting.people, save: { _ in }, cancel: {}), "people-editor-calendar", size: CGSize(width: 290, height: 270))
            }
            if !pass { ok = false }
            for id in also.map(\.id) { library.unlink(id) }
            for _ in 0..<40 where library.detail?.meeting.linkedEvent != nil { try? await Task.sleep(for: .milliseconds(50)) }
        }
        // Speaker rename (T60): with the meeting's people as suggestions, and without.
        let renameSpeaker = Speaker(id: SpeakerID("render-s1"), label: "Speaker 1", displayName: "Dana Whitfield")
        let renamePeople = ["Dana Whitfield", "Ravi Patel", "Mei Chen", "Tomás Ortega", "Alex Martin"].map { Person(name: $0) }
        _ = await host(SpeakerRenameSheet(speaker: renameSpeaker, text: .constant("Dana Whitfield"),
                                          suggestions: SpeakerMenu.renameSuggestions(renamePeople, for: renameSpeaker)) {}, "speaker-rename-people", size: CGSize(width: 420, height: 260))
        _ = await host(SpeakerRenameSheet(speaker: Speaker(id: SpeakerID("render-s2"), label: "Speaker 2"), text: .constant(""), suggestions: []) {},
                       "speaker-rename-no-people", size: CGSize(width: 420, height: 160))
        // Sidebar alone (split-view sidebars use vibrancy that offscreen capture may not draw).
        _ = await host(LibrarySidebar(), "sidebar", size: CGSize(width: 180, height: 760))   // T80: the ideal width
        // T40: the folder filter. All meetings above; here one folder's meetings, and the counts beside each row.
        let rows = library.folderRows
        let rowsOK = rows.map(\.name) == [LibraryFolders.allMeetingsTitle, LibraryFolders.unsortedTitle, "Acme", "Hiring"]
            && rows.map(\.count) == [library.items.count, library.items.count - 3, 2, 1]
        library.folderFilter = library.folders.first.map { .folder($0.id) } ?? .all
        var filteredOK = Set(library.visibleItems.map(\.id)) == [MeetingID("ui-long"), MeetingID("fx-two-source")]
        _ = await host(LibrarySidebar(), "sidebar-folder", size: CGSize(width: 180, height: 760))
        library.folderFilter = library.folders.last.map { .folder($0.id) } ?? .all
        _ = await host(LibrarySidebar(), "sidebar-folder-hiring", size: CGSize(width: 180, height: 400))
        // T83: Unsorted lists only the meetings in no folder.
        library.folderFilter = .unsorted
        filteredOK = filteredOK && !library.visibleItems.isEmpty && library.visibleItems.allSatisfy { $0.folderID == nil }
            && AskScope.options(folderShown: library.filteredFolder != nil) == [.thisMeeting, .allMeetings]
        _ = await host(LibrarySidebar(), "sidebar-unsorted", size: CGSize(width: 180, height: 760))
        // A Folder scope in Ask becomes All meetings when the sidebar switches from a folder to Unsorted.
        library.folderFilter = library.folders.first.map { .folder($0.id) } ?? .all
        library.askScope = .thisFolder
        library.folderFilter = .unsorted
        filteredOK = filteredOK && library.askScope == .allMeetings
        library.askScope = .thisMeeting
        library.folderFilter = .all
        // T41: the drag payload survives the trip through its private type (the drop logic is LibraryFolders.dropMoves).
        let dragData = try? await DraggedMeeting(MeetingID("ui-long")).exported(as: .amaranthMeeting)
        var dragOK = false
        if let dragData, let back = try? await DraggedMeeting(importing: dragData, contentType: .amaranthMeeting) { dragOK = back.meetingID == MeetingID("ui-long") }
        SelfTest.log(["step": "meeting-drag-payload", "ok": "\(dragOK)"])
        if !dragOK { ok = false }
        SelfTest.log(["step": "folders", "rows": rows.map { "\($0.name) \($0.count)" }.joined(separator: " | "), "ok": "\(rowsOK && filteredOK)"])
        if !(rowsOK && filteredOK) { ok = false }
        _ = await host(AskPane(), "ask-pane-empty", size: CGSize(width: 260, height: 760))
        // Toolbar recorder (T31): idle control, this meeting's options, the strip in each state, the banner.
        _ = await host(RecordToolbarControl(model: recorder).padding(), "record-control", size: CGSize(width: 260, height: 60))
        _ = await host(RecordOptionsForm(model: recorder) {}, "record-options", size: CGSize(width: 360, height: 420))
        _ = await host(VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(stripSamples.enumerated()), id: \.offset) { _, s in
                RecordingStripContent(state: s.0, elapsed: 3723, health: s.1, savedUpTo: [.microphone: 3720, .systemOutput: 3700],
                                      diskWarning: s.2, folder: nil, pause: {}, resume: {}, stop: {})
            }
        }.padding(), "recording-strip", size: CGSize(width: 520, height: 360))
        // The calendar question in the strip (T59): one match, several.
        let promptEvents = Self.calendarEvents(on: Date())
        _ = await host(VStack(alignment: .leading, spacing: 14) {
            ForEach(Array([CalendarSuggestion.Prompt.one(promptEvents[0]), .one(Self.longTitleEvent), .several(Array(promptEvents.prefix(2)))].enumerated()), id: \.offset) { _, p in
                RecordingStripContent(state: .recording, elapsed: 75, health: stripSamples[0].1, savedUpTo: [:], diskWarning: nil, folder: nil,
                                      pause: {}, resume: {}, stop: {}, eventPrompt: p)
            }
        }.padding(), "recording-strip-calendar", size: CGSize(width: 720, height: 170))
        // T68: the amber "Quiet" strip (quiet and call-ended) and its popover.
        let quietAlerts = [QuietMonitor.Alert(reason: .quiet, quietSince: 3723 - 72, usedLevels: false),
                           QuietMonitor.Alert(reason: .callEnded, quietSince: 3723 - 41, usedLevels: false)]
        _ = await host(VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(quietAlerts.enumerated()), id: \.offset) { _, q in
                RecordingStripContent(state: .recording, elapsed: 3723, health: stripSamples[0].1, savedUpTo: [:], diskWarning: nil, folder: nil,
                                      pause: {}, resume: {}, stop: {}, quiet: q)
            }
        }.padding(), "recording-strip-quiet", size: CGSize(width: 520, height: 110))
        _ = await host(QuietAlertDetails(alert: quietAlerts[0], now: 3723, stop: {}, keep: {}), "quiet-alert-popover", size: CGSize(width: 320, height: 190))
        _ = await host(EventPromptChoices(prompt: .one(promptEvents[0]), link: { _ in }, dismiss: {}), "event-prompt-one", size: CGSize(width: 300, height: 170))
        _ = await host(EventPromptChoices(prompt: .several(Array(promptEvents.prefix(2))), link: { _ in }, dismiss: {}), "event-prompt-several", size: CGSize(width: 300, height: 220))
        // Health popover content (T34).
        _ = await host(RecordingHealthDetails(health: [
            .init(source: .microphone, status: .healthy, peakLevelDBFS: -18, deviceName: "MacBook Pro Microphone"),
            .init(source: .systemOutput, status: .silent, peakLevelDBFS: -90, deviceName: "System audio"),
        ], savedUpTo: [.microphone: 3720, .systemOutput: 3700], now: 3723, diskWarning: RecorderPresentation.diskWarning(secondsLeft: 900),
           folder: "/Users/example/Library/Application Support/Amaranth/meetings/2026-10-25-m1"), "recording-health", size: CGSize(width: 380, height: 260))
        // Live view (T33): scratchpad closed by default, then open above the transcript.
        _ = await host(LiveTranscriptView(), "live-scratchpad-closed", size: CGSize(width: 900, height: 400))
        // The live view where MainView shows it while recording: the detail column of the split view.
        _ = await host(NavigationSplitView { LibrarySidebar() } detail: {
            LiveTranscriptView().safeAreaInset(edge: .top, spacing: 0) { RecorderBanner(model: recorder) }
        }, "live-in-window", size: CGSize(width: 1200, height: 760))
        recorder.scratchpadOpen = true
        recorder.scratchpad = "Ask Dana about the notarization date"
        _ = await host(LiveTranscriptView(), "live-scratchpad-open", size: CGSize(width: 900, height: 400))
        recorder.scratchpadOpen = false
        recorder.scratchpad = ""
        _ = await host(RecorderBannerContent(items: [
            .init(kind: .error, text: "Could not start recording: example error"),
            .init(kind: .permission, text: "Amaranth isn't allowed to record microphone. Allow it in System Settings → Privacy & Security."),
            .init(kind: .notice, text: RecordingDefaults.missingMicrophoneNotice),
            .init(kind: .recovery, text: "Recovered 1 interrupted recording(s): 3 audio segment(s) restored."),
            .init(kind: .result, text: "Saved 12 segments (62 s) to /Users/example/Library/Application Support/Amaranth/meetings/m1"),
        ], dismiss: { _ in }), "recorder-banner", size: CGSize(width: 900, height: 200))
        // Settings → Recording defaults (T30).
        _ = await host(RecordingSettings(recorder: recorder), "settings-recording", size: CGSize(width: 560, height: 560))
        // Settings → Calendar (T59, T61): access allowed, and not yet set up.
        _ = await host(CalendarSettingsView(calendar: calendar, recorder: recorder, library: library).defaultAppStorage(collapsed), "settings-calendar", size: CGSize(width: 560, height: 620))
        collapsed.set(true, forKey: CalendarSettings.reminderKey)
        _ = await host(CalendarSettingsView(calendar: calendar, recorder: recorder, library: library).defaultAppStorage(collapsed), "settings-calendar-reminder-on", size: CGSize(width: 560, height: 700))
        collapsed.removeObject(forKey: CalendarSettings.reminderKey)
        _ = await host(CalendarSettingsView(calendar: CalendarModel(source: FakeCalendarSource(status: .notDetermined)), recorder: recorder).defaultAppStorage(collapsed),
                       "settings-calendar-not-set-up", size: CGSize(width: 560, height: 460))
        // Settings → Appearance: transcript style cards, each selected in turn (throwaway defaults, at the Settings size).
        _ = await host(AppearanceSettings().defaultAppStorage(collapsed), "settings-appearance-columns", size: CGSize(width: 560, height: 460))
        collapsed.set(TranscriptStyle.bubbles.rawValue, forKey: TranscriptStyle.key)
        _ = await host(AppearanceSettings().defaultAppStorage(collapsed), "settings-appearance-bubbles", size: CGSize(width: 560, height: 460))
        collapsed.removeObject(forKey: TranscriptStyle.key)
        // Sun/moon toggle (T44): the sun in dark mode, the moon in light mode. Then the main window's real toolbar
        // (bridged into an NSWindow) to check the toggle and the Ask pane toggle are there. Export moved to the meeting header
        // (Inner Circle handoff), so it must not be in the toolbar any more.
        _ = await host(AppearanceToggle().labelStyle(.iconOnly).padding(), "appearance-toggle", size: CGSize(width: 60, height: 44))
        if let first = library.items.first {
            library.selection = first.id
            for _ in 0..<40 where library.detail?.meeting.id != first.id { try? await Task.sleep(for: .milliseconds(50)) }
            let view = NSHostingView(rootView: MainView().textSize(textSize).environment(worker).environment(models).environment(recorder)
                .environment(library).environment(playback).environment(live).environment(calendar).frame(width: 1200, height: 760))
            view.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = view
            try? await Task.sleep(for: .milliseconds(600))
            let labels = window.toolbar?.items.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label } ?? []
            let toggle = labels.firstIndex { $0.hasPrefix("Switch to") }
            let expected = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "Switch to Light Mode" : "Switch to Dark Mode"
            // T77: no models button in the toolbar any more (Settings → Models and the sidebar footer).
            let pass = toggle != nil && labels[toggle!] == expected && !labels.contains("Export") && labels.contains { $0.hasSuffix("Ask") }
                && !labels.contains { $0.localizedCaseInsensitiveContains("model") }
                // T86: the sun/moon then the Ask toggle end the toolbar (their positions are checked on the real window by
                // StopLayoutProbe's toolbar-corner steps).
                && labels.suffix(2).first == expected && labels.last?.hasSuffix("Ask") == true
            SelfTest.log(["step": "toolbar", "items": labels.joined(separator: " | "), "ok": "\(pass)"])
            // The whole window including its title bar and toolbar (the window frame view, not just the content).
            if let frameView = window.contentView?.superview {
                let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "main-toolbar.png"))
            }
            if !pass { ok = false }
            window.contentView = nil
            #if DEBUG
            // While recording, with the sidebar open: the whole strip, Stop included, must be on the toolbar, not in its
            // overflow menu, at the default window width and a narrower one.
            recorder.showStripForRender(.recording, health: [
                .init(source: .microphone, status: .healthy, peakLevelDBFS: -18, deviceName: "MacBook Pro Microphone"),
                .init(source: .systemOutput, status: .healthy, peakLevelDBFS: -24, deviceName: "System audio")])
            // T59: also with the calendar question showing (a long title, and "Which meeting?").
            // T68: and with the amber "Still recording?" quiet time (alone, and with the calendar question).
            let quiet = QuietMonitor.Alert(reason: .quiet, quietSince: 3723 - 72, usedLevels: false)
            let prompts: [(String, CalendarSuggestion.Prompt, QuietMonitor.Alert?)] = [
                ("", .none, nil), ("-calendar-one", .one(Self.longTitleEvent), nil),
                ("-calendar-several", .several(Array(Self.calendarEvents(on: Date()).prefix(2))), nil),
                ("-quiet", .none, quiet), ("-quiet-calendar-one", .one(Self.longTitleEvent), quiet)]
            for (suffix, prompt, quietAlert) in prompts {
            recorder.showStripForRender(.recording, health: [
                .init(source: .microphone, status: .healthy, peakLevelDBFS: -18, deviceName: "MacBook Pro Microphone"),
                .init(source: .systemOutput, status: .healthy, peakLevelDBFS: -24, deviceName: "System audio")], prompt: prompt, quiet: quietAlert)
            for width in [1100.0, 900.0] {
                let rec = NSHostingView(rootView: MainView().textSize(textSize).environment(worker).environment(models).environment(recorder)
                    .environment(library).environment(playback).environment(live).environment(calendar).frame(width: width, height: 600))
                rec.sceneBridgingOptions = [.toolbars]
                let recWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                recWindow.appearance = appearance
                recWindow.contentView = rec
                // On screen (briefly): offscreen windows don't split the toolbar between the sidebar and detail columns,
                // which is where the strip used to overflow.
                recWindow.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(900))
                let items = recWindow.toolbar?.items ?? [], visible = recWindow.toolbar?.visibleItems ?? []
                let hidden = items.filter { item in !visible.contains { $0 === item } }
                    .map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label }
                let pass = hidden.isEmpty
                SelfTest.log(["step": "toolbar-recording", "prompt": suffix.isEmpty ? "none" : String(suffix.dropFirst()), "width": "\(Int(width))",
                              "items": "\(items.count)", "hidden": hidden.joined(separator: " | "), "ok": "\(pass)"])
                if !pass { ok = false }
                if let frameView = recWindow.contentView?.superview {
                    let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "main-recording-toolbar-\(Int(width))\(suffix).png"))
                }
                recWindow.orderOut(nil)
                recWindow.contentView = nil
            }
            }
            recorder.showStripForRender(nil)
            #endif
        }
        // Onboarding, the model sheet and the menu-bar menu's items (T43: every screen in both appearances).
        _ = await host(OnboardingView {}, "onboarding", size: CGSize(width: 560, height: 520))
        // T77: model setup lives only in Settings → Models (at the Settings size); the sidebar footer in each state.
        _ = await host(ModelSetupView(model: models).frame(maxHeight: .infinity, alignment: .top), "settings-models", size: CGSize(width: 560, height: 640))
        for (kind, name) in [(LocalModelFooter.Kind.ready, "ready"), (.installing, "installing"), (.missing, "missing")] {
            _ = await host(LocalModelFooter(state: kind).background(Color.canvas), "sidebar-footer-\(name)", size: CGSize(width: 200, height: 40))
        }
        _ = await host(VStack(alignment: .leading, spacing: 6) { MenuBarContent(recorder: recorder) }.padding(), "menu-bar", size: CGSize(width: 260, height: 180))
        // Switching meetings: frames straight after the selection changes, while the next meeting loads.
        if library.items.count >= 2 {
            library.selection = library.items[0].id
            let view = makeView(MainView(), size: CGSize(width: 1200, height: 760))
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))
            library.selection = library.items[1].id
            for (i, ms) in [0, 20, 60, 200].enumerated() {
                try? await Task.sleep(for: .milliseconds(ms))
                view.layoutSubtreeIfNeeded()
                capture(view, "switch-frame-\(i)")
            }
        }
        // Ask anything (T52): the field at the bottom of the detail column, the panel in each scope, keyboard selection,
        // and Return on a hit landing on its transcript row, also when the hit is in a meeting that isn't open yet.
        if let long = library.items.first(where: { $0.id == MeetingID("ui-long") }), let other = library.items.first(where: { $0.id != long.id }) {
            func select(_ id: MeetingID) async {
                library.selection = id
                for _ in 0..<40 where library.detail?.meeting.id != id { try? await Task.sleep(for: .milliseconds(50)) }
            }
            await select(long.id)
            _ = await host(MainView(), "ask-bar", size: CGSize(width: 1200, height: 760))
            library.askScope = .thisMeeting
            library.query = "release"
            library.submitAsk()
            let thisHits = library.hits
            let thisOK = !thisHits.isEmpty && thisHits.allSatisfy { $0.meetingID == long.id }
            library.moveAskSelection(by: 1); library.moveAskSelection(by: 1); library.moveAskSelection(by: -1)
            // Return commits the field, which sets the same text again: that must keep the highlight (validator must-fix).
            library.query = library.query
            let selOK = library.askSelection == 0
            _ = await host(MainView(), "ask-this-meeting", size: CGSize(width: 1200, height: 760))
            _ = await host(AskPane(), "ask-pane-results", size: CGSize(width: 260, height: 760))
            library.askAllMeetings()
            let allOK = library.askScope == .allMeetings && library.hits.count >= thisHits.count
            _ = await host(MainView(), "ask-all-meetings", size: CGSize(width: 1200, height: 760))
            library.query = "zzqx-no-such-word"
            _ = await host(MainView(), "ask-no-matches", size: CGSize(width: 1200, height: 760))
            // Open the second hit of the long meeting with ↓↓ Return, starting from another meeting.
            library.closeAskPanel()
            await select(other.id)
            library.askScope = .allMeetings
            library.query = "release"
            library.submitAsk()
            let shown = AskResults.flattened(AskResults.grouped(library.hits))
            var target: SearchHit?
            if let i = shown.indices.filter({ shown[$0].meetingID == long.id && shown[$0].kind == .transcript }).dropFirst().first {
                library.askSelection = nil
                for _ in 0...i { library.moveAskSelection(by: 1) }
                target = shown[i]
                library.submitAsk()
            }
            for _ in 0..<40 where library.focusRowID == nil { try? await Task.sleep(for: .milliseconds(50)) }
            let row = library.detail?.rows.first { $0.id == library.focusRowID }
            let jumpOK = target != nil && library.selection == long.id && library.detailTab == .transcript && library.askPanelOpen
                && row?.segmentID?.rawValue == target?.ref
            SelfTest.log(["step": "ask", "thisMeetingHits": "\(thisHits.count)", "allHits": "\(library.hits.count)", "thisScopeOK": "\(thisOK)",
                          "allScopeOK": "\(allOK)", "arrowsOK": "\(selOK)", "jumpRow": library.focusRowID ?? "-", "ok": "\(thisOK && allOK && selOK && jumpOK)"])
            if !(thisOK && allOK && selOK && jumpOK) { ok = false }
            // T78: × / Esc clears the question too and asks for the field's focus.
            let focusBefore = library.askFocusRequest
            library.clearAsk()
            let clearOK = library.query.isEmpty && !library.askPanelOpen && library.hits.isEmpty && library.askFocusRequest == focusBefore + 1
            SelfTest.log(["step": "ask-clear", "query": library.query, "panelOpen": "\(library.askPanelOpen)",
                          "focusRequested": "\(library.askFocusRequest > focusBefore)", "ok": "\(clearOK)"])
            if !clearOK { ok = false }
            library.focusRowID = nil
            // T42: with Acme shown, “This folder” limits hits to its meetings (ui-long, fx-two-source); showing All
            // meetings turns the scope back to All meetings.
            let acmeIDs: Set<MeetingID> = [MeetingID("ui-long"), MeetingID("fx-two-source")]
            library.folderFilter = library.folders.first { $0.name == "Acme" }.map { .folder($0.id) } ?? .all
            library.askScope = .thisFolder
            library.query = "launch release"
            library.submitAsk()
            let folderHits = library.hits
            let folderOK = !folderHits.isEmpty && folderHits.allSatisfy { acmeIDs.contains($0.meetingID) } && library.askFolder != nil
            _ = await host(AskPane(), "ask-pane-folder", size: CGSize(width: 260, height: 760))
            library.folderFilter = .all
            let resetOK = library.askScope == .allMeetings && library.askFolder == nil
            library.clearAsk()
            SelfTest.log(["step": "ask-folder", "folderHits": "\(folderHits.count)", "resetOK": "\(resetOK)", "ok": "\(folderOK && resetOK)"])
            if !(folderOK && resetOK) { ok = false }
        }
        // The sidebar has no search field any more (T52); ⌘K focuses the ask field instead.
        // Answers (T54): a finished answer with citation chips above the matches, waiting, and a refusal.
        #if DEBUG
        if let launch = library.items.first(where: { $0.id == Fixtures.twoSourceConversation.meeting.id }) {
            library.selection = launch.id
            for _ in 0..<40 where library.detail?.meeting.id != launch.id { try? await Task.sleep(for: .milliseconds(50)) }
            let passages = (try? Retriever(store: store).search("When will they ship?", in: launch.id)) ?? []
            let cites = Array(1...min(2, passages.count))
            library.askScope = .thisMeeting
            library.query = "When will they ship?"
            library.submitAsk()   // the matches; the answer is shown directly below (no model here)
            let answers = AnswerModel(store: store, worker: nil)
            library.answers = answers
            answers.showForRender(question: "When will they ship?", passages: passages, response: AnswerResponse(
                text: "They decided to ship on Thursday, not Wednesday, once Dana finishes notarization.", citations: cites, confidence: .high,
                refused: false, promptTokens: 0, generatedTokens: 0, firstTextSeconds: nil, totalSeconds: 0), phase: .done, acrossMeetings: false)
            _ = await host(MainView(), "ask-answer", size: CGSize(width: 1200, height: 760))
            _ = await host(AskPane(), "ask-pane-answer", size: CGSize(width: 260, height: 760))
            answers.showForRender(question: "When will they ship?", passages: passages, response: AnswerResponse(
                text: "They decided to ship on Thursday, not Wednesday.", citations: cites, confidence: .high, refused: false,
                promptTokens: 0, generatedTokens: 0, firstTextSeconds: nil, totalSeconds: 0), phase: .done, acrossMeetings: true)
            _ = await host(MainView(), "ask-answer-all-meetings", size: CGSize(width: 1200, height: 760))
            answers.showForRender(question: "When will they ship?", passages: passages, response: nil,
                                  phase: .waiting("Waiting for transcription to finish… The search matches are below."), acrossMeetings: false)
            _ = await host(MainView(), "ask-answer-waiting", size: CGSize(width: 1200, height: 760))
            answers.showForRender(question: "What did they say about the budget?", passages: passages, response: AnswerResponse(
                text: AnswerResponse.refusalText, citations: [], confidence: .low, refused: true, promptTokens: 0, generatedTokens: 0,
                firstTextSeconds: nil, totalSeconds: 0), phase: .done, acrossMeetings: false)
            _ = await host(MainView(), "ask-answer-refused", size: CGSize(width: 1200, height: 760))
            // A follow-up (T55): the earlier turn shows above the answer.
            answers.showForRender(question: "And who is finishing notarization?", passages: passages, response: AnswerResponse(
                text: "Dana will finish notarization by Wednesday.", citations: cites, confidence: .high, refused: false, promptTokens: 0,
                generatedTokens: 0, firstTextSeconds: nil, totalSeconds: 0), phase: .done, acrossMeetings: false,
                history: [AnswerTurn(question: "When will they ship?", answer: "They decided to ship on Thursday, not Wednesday.")])
            _ = await host(MainView(), "ask-answer-follow-up", size: CGSize(width: 1200, height: 760))
            // A cross-meeting citation (T55) opens its own meeting at the cited line, from another meeting.
            if let target = passages.first, let other = library.items.first(where: { $0.id != launch.id })?.id {
                library.selection = other
                for _ in 0..<40 where library.detail?.meeting.id != other { try? await Task.sleep(for: .milliseconds(50)) }
                library.focusRowID = nil
                library.open(citation: target)
                for _ in 0..<40 where library.focusRowID == nil { try? await Task.sleep(for: .milliseconds(50)) }
                let pass = library.selection == launch.id && library.detail?.meeting.id == launch.id && library.detailTab == .transcript
                    && library.focusRowID != nil
                SelfTest.log(["step": "ask-cross-citation", "from": other.rawValue, "to": launch.id.rawValue, "row": library.focusRowID ?? "-", "ok": "\(pass)"])
                if !pass { ok = false }
                library.focusRowID = nil
            }
            // A citation chip opens the cited line in the transcript.
            if let first = answers.citedPassages.first ?? passages.first {
                library.open(citation: first)
                for _ in 0..<20 where library.focusRowID == nil { try? await Task.sleep(for: .milliseconds(50)) }
                let pass = library.detailTab == .transcript && library.focusRowID != nil
                SelfTest.log(["step": "ask-answer", "passages": "\(passages.count)", "citationJumpRow": library.focusRowID ?? "-", "ok": "\(pass)"])
                if !pass { ok = false }
            }
            library.closeAskPanel(); library.query = ""; library.focusRowID = nil; library.answers = nil
        }
        #endif
        return ok
    }

    static func table(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for v in view.subviews { if let t = table(in: v) { return t } }
        return nil
    }

    /// A day of fixture events around `date` (T57): the linked one first, a declined one, an all-day one, a cancelled
    /// one (never shown), and attendees including a room and an unnamed guest.
    static func calendarEvents(on date: Date) -> [CalendarEvent] {
        let t = date.addingTimeInterval(-300)
        let people = [CalendarAttendee(name: "Alex Martin", isCurrentUser: true), CalendarAttendee(name: "Dana Whitfield"),
                      CalendarAttendee(name: "Ravi Patel"), CalendarAttendee(name: "Room 4B", kind: .room), CalendarAttendee(name: nil, email: "guest@example.com")]
        return [
            CalendarEvent(identifier: "evt-roadmap", title: "Roadmap sync", start: t, end: t.addingTimeInterval(1800), calendarName: "Work", attendees: people),
            CalendarEvent(identifier: "evt-1on1", title: "1:1 with Dana", start: t.addingTimeInterval(3600), end: t.addingTimeInterval(5400), isRecurring: true,
                          calendarName: "Work", attendees: [CalendarAttendee(name: "Alex Martin", response: .declined, isCurrentUser: true)]),
            CalendarEvent(identifier: "evt-lunch", title: "Team lunch", start: t.addingTimeInterval(-7200), end: t.addingTimeInterval(-3600), calendarName: "Home"),
            CalendarEvent(identifier: "evt-cancelled", title: "Cancelled standup", start: t, end: t.addingTimeInterval(900), isCancelled: true, calendarName: "Work"),
            CalendarEvent(identifier: "evt-offsite", title: "Offsite week", start: Calendar.current.startOfDay(for: date),
                          end: Calendar.current.startOfDay(for: date).addingTimeInterval(86_400), isAllDay: true, calendarName: "Work"),
        ]
    }

    /// A long event title, to check the strip's question truncates instead of pushing Stop into the toolbar overflow.
    static let longTitleEvent = CalendarEvent(identifier: "evt-long", title: "Quarterly roadmap sync with the platform and infrastructure teams",
                                              start: Date(), end: Date().addingTimeInterval(3600), calendarName: "Work")

    /// Every SourceHealth status appears in at least one strip, plus the low-disk glyph.
    static let stripSamples: [(CaptureState, [SourceHealth], String?)] = [
        (.recording, [.init(source: .microphone, status: .healthy, deviceName: "MacBook Pro Microphone"), .init(source: .systemOutput, status: .silent)], nil),
        (.recording, [.init(source: .microphone, status: .clipping), .init(source: .systemOutput, status: .degraded)],
         RecorderPresentation.diskWarning(secondsLeft: 900)),
        (.paused, [.init(source: .microphone, status: .failed), .init(source: .systemOutput, status: .permissionDenied)], nil),
        (.interrupted, [.init(source: .microphone, status: .starting), .init(source: .systemOutput, status: .inactive)], nil),
        (.preparing, [], nil),
        (.stopping, [.init(source: .microphone, status: .healthy)], nil),
    ]

    static func persistFixture(_ f: FixtureMeeting, _ store: MeetingStore) throws {
        try store.upsertMeeting(f.meeting)
        try store.insertEpochs(f.epochs)
        try store.insertSegments(f.audioSegments)
        try store.insertEvents(f.events)
        if let t = f.transcript { try store.publishTranscript(t) }
        for e in f.edits { try store.appendEdit(e) }
        if let s = f.summary { try store.publishSummary(s) }
        for j in f.jobs { try store.upsertJob(j) }
    }

    /// Two hours, four speakers, mixed sources, a failed region and an unknown-speaker word per segment.
    static func persistLongMeeting(_ store: MeetingStore) throws {
        let m = MeetingID("ui-long")
        let speakers = (1...4).map { Speaker(id: SpeakerID("long-s\($0)"), label: "Speaker \($0)") }
        var segs: [TranscriptSegment] = []
        for i in 0..<1800 {
            let t0 = Double(i) * 4
            let source: SourceKind = i % 3 == 0 ? .microphone : .systemOutput
            var words: [Word] = []
            for j in 0..<24 {
                let a = t0 + Double(j) * 0.14
                let who: SpeakerAssignment = j == 23 ? .unknown : .speaker(speakers[i % 4].id)
                words.append(Word(id: WordID("l\(i)-\(j)"), text: j == 5 ? "release" : "word\(j)", interval: .seconds(a, a + 0.12), source: source, speaker: who))
            }
            segs.append(TranscriptSegment(id: TranscriptSegmentID("ls\(i)"), source: source, interval: .seconds(t0, t0 + 3.4), words: words, speaker: .speaker(speakers[i % 4].id)))
        }
        try store.upsertMeeting(Meeting(id: m, title: "Two-hour planning session", createdAt: Date(), captureState: .captured, duration: .seconds(7200)))
        let t = TranscriptRevision(meetingID: m, kind: .final, stage: .attributed, createdAt: Date(), producer: ProducerInfo(component: "ui", configHash: "ui"),
                                   segments: segs, coverage: [CoverageRegion(source: .systemOutput, interval: .seconds(0, 3000), status: .transcribed),
                                                              CoverageRegion(source: .systemOutput, interval: .seconds(3000, 3040), status: .failed),
                                                              CoverageRegion(source: .systemOutput, interval: .seconds(3040, 7200), status: .transcribed)],
                                   speakers: speakers)
        try store.publishTranscript(t)
    }
}
