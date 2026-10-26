import SwiftUI
import AppKit
import Presentation

/// Export action published by the open meeting (nil when it has no transcript), for the menu's ⌘E.
struct ExportAction { let run: () -> Void }

extension FocusedValues {
    @Entry var exportMarkdown: ExportAction?
}

/// T29: menu-bar commands for the meeting screen. Each shortcut is registered once, here or on its control: ⌘D lives on
/// the Details button (T22) and the menu item only toggles the same preference; ⌘⇧R/P/S live on the recorder buttons.
struct MeetingCommands: Commands {
    let library: LibraryModel
    @FocusedValue(\.exportMarkdown) private var exportMarkdown
    @AppStorage(ReviewPreferences.showDetailsKey) private var showDetails = ReviewPreferences.showDetailsDefault
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    /// Menu shortcuts must not act behind a sheet (rename, correct text, model setup, onboarding).
    var sheetOpen: Bool { NSApp.windows.contains { $0.attachedSheet != nil } }

    var body: some Commands {
        CommandMenu("Meeting") {
            ForEach(Array(LibraryModel.DetailTab.allCases.enumerated()), id: \.offset) { i, tab in
                Button(tab.rawValue) { if !sheetOpen { library.detailTab = tab } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .disabled(library.detail == nil)
            }
            Divider()
            Button("Export Markdown…") { if !sheetOpen { exportMarkdown?.run() } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exportMarkdown == nil)
            Divider()
            Button("Search Meetings") { if !sheetOpen { library.searchFocusRequest += 1 } }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Details", isOn: $showDetails)   // ⌘D is on the Details button (T22)
            // T44: the toolbar sun/moon button does the same; ⌘⇧L is registered only here so it works in every window.
            Button(AppAppearance.toggleMenuTitle(effectiveIsDark: appearance == AppAppearance.dark.rawValue || (appearance == AppAppearance.system.rawValue && AppAppearance.effectiveIsDark))) {
                appearance = AppAppearance.toggled(effectiveIsDark: AppAppearance.effectiveIsDark).rawValue
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
