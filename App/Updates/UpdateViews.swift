import SwiftUI
import AppKit
import Presentation

/// Amaranth ▸ Check for Updates… (T71): opens the Software Update window and checks.
struct UpdateCommands: Commands {
    let updates: UpdateModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                openWindow(id: UpdateWindow.id)
                NSApp.activate()
                updates.check(userInitiated: true)
            }
        }
    }
}

/// The launch check's quiet note (T71, user choice 2026-11-02): a toolbar button while a newer build exists, until Later.
struct UpdateToolbarNote: View {
    let updates: UpdateModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch updates.note {
        case .available(let c)?:
            Button { openWindow(id: UpdateWindow.id) } label: {
                Label("Update Available", systemImage: "arrow.down.circle")
            }
            .help("Amaranth \(c.manifest.label) is available (you have \(updates.running.label)). Click for details.")
            .accessibilityLabel("Update available: build \(c.manifest.build)")
        case .updated(let build)?:
            // T72: once, after an in-app update; clicking it (or the next launch) clears it.
            Button { updates.updatedFrom = nil } label: {
                Label("Updated to build \(build)", systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
            }
            .help("Amaranth was updated from build \(updates.updatedFrom ?? 0) to \(updates.running.label). Click to dismiss.")
        case .failed(let build)?:
            Button { openWindow(id: UpdateWindow.id) } label: {
                Label("Update Didn't Install", systemImage: "exclamationmark.triangle")
            }
            .help("Build \(build) couldn't be installed; this build was kept. Click for details.")
        case nil:
            EmptyView()
        }
    }
}

/// The Software Update window: current vs available build, what changed, Install and Relaunch / Later.
struct UpdateWindow: View {
    static let id = "updates"
    let updates: UpdateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandMark(size: 36)
                Text(title).appFont(.title)
            }
            content
        }
        .padding(20)
        .frame(width: 460, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.surface)
        // Opened by state restoration rather than the menu: check, rather than show "Checking…" forever.
        .onAppear { if updates.phase == .idle { updates.check(userInitiated: true) } }
    }

    private var title: String {
        switch updates.phase {
        case .available: "A new build is available"
        case .upToDate: "You're up to date"
        case .failed: updates.failedBuild != nil ? "The update didn't install" : "Couldn't check for updates"
        case .checking, .idle: "Software Update"
        }
    }

    @ViewBuilder private var content: some View {
        switch updates.phase {
        case .idle, .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking for updates…").foregroundStyle(Color.brandSecondary) }
            buttons { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        case .upToDate:
            Text("Amaranth \(updates.running.label) is the newest build\(UpdateSettings.includeDebug() ? ", debug builds included" : "").")
                .foregroundStyle(Color.brandSecondary)
            sourceLine
            buttons { Button("OK") { dismiss() }.keyboardShortcut(.defaultAction).accessibilityLabel("OK") }
        case .failed(let message):
            Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.statusAttention) }
            sourceLine
            buttons {
                Button("Close") { updates.later(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(updates.failedBuild != nil ? "Check Again" : "Try Again") {
                    updates.failedBuild = nil
                    updates.check(userInitiated: true)
                }
                .keyboardShortcut(.defaultAction)
            }
        case .available(let c):
            available(c)
        }
    }

    @ViewBuilder private func available(_ c: UpdateCandidate) -> some View {
        let m = c.manifest
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.trailing)
                Text("Build").foregroundStyle(Color.brandSecondary)
                Text("Channel").foregroundStyle(Color.brandSecondary)
                Text("Commit").foregroundStyle(Color.brandSecondary)
            }
            .appFont(.caption)
            GridRow {
                Text("You have").foregroundStyle(Color.brandSecondary)
                Text("\(updates.running.version) (\(updates.running.build))").monospacedDigit()
                Text(updates.running.channel == .debug ? "Debug" : "Release")
                Text(updates.running.commitLabel).monospaced()
            }
            GridRow {
                Text("Available").foregroundStyle(Color.brandSecondary)
                Text("\(m.version) (\(m.build))").monospacedDigit().bold()
                Text(m.buildChannel == .debug ? "Debug" : "Release")
                Text(m.commit).monospaced()
            }
        }
        if !m.changes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("What's changed").appFont(.sectionTitle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(m.changes.enumerated()), id: \.offset) { _, line in
                            Text("•  \(line)").fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .appFont(.callout)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }
        }
        Text("Amaranth quits, replaces itself with this build and opens again. Your meetings, settings and permissions stay as they are. \(Self.sizeText(m.size)) download.")
            .appFont(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
        if updates.processingPending() {
            Text("Processing in progress picks up again after the relaunch; the step it's on starts over.")
                .appFont(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
        }
        switch updates.installPhase {
        case .downloading(let fraction):
            HStack(spacing: 10) {
                if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text("Downloading…").appFont(.caption).foregroundStyle(Color.brandSecondary)
            }
            buttons { Button("Cancel") { updates.cancelInstall() }.keyboardShortcut(.cancelAction).accessibilityLabel("Cancel") }
        case .verifying:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the download…").foregroundStyle(Color.brandSecondary) }
            buttons { Button("Cancel") { updates.cancelInstall() }.keyboardShortcut(.cancelAction).accessibilityLabel("Cancel") }
        case .relaunching:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Relaunching…").foregroundStyle(Color.brandSecondary) }
        case .idle, .failed:
            if case .failed(let message) = updates.installPhase {
                Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.statusAttention)
                }
            } else if let blocker = updates.installBlocker {
                Label { Text(blocker).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "info.circle").foregroundStyle(Color.brandSecondary)
                }
                .appFont(.callout)
            }
            buttons {
                Button("Later") { updates.later(); updates.installPhase = .idle; dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Later")
                Button("Install and Relaunch") { updates.install(c) }.keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Install and Relaunch")
                    .disabled(updates.installBlocker != nil)
            }
        }
    }

    @ViewBuilder private var sourceLine: some View {
        Text(Self.sourceDescription).appFont(.caption).foregroundStyle(Color.brandSecondary)
    }

    static var sourceDescription: String {
        switch UpdateSettings.source() {
        case .github: "Builds from GitHub (\(GitHubReleasesSource.defaultRepository)). Change this in Settings → Updates."
        case .folder: "Builds from \(UserDefaults.standard.string(forKey: UpdateSettings.folderPathKey) ?? "a local folder"). Change this in Settings → Updates."
        case .off: "Update checks are off in Settings → Updates."
        }
    }

    static func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func buttons<B: View>(@ViewBuilder _ b: () -> B) -> some View {
        HStack { Spacer(); b() }.padding(.top, 4)
    }
}

/// Settings → Updates (T71): where builds come from, the Debug opt-in, the launch check, and Check Now.
struct UpdateSettingsView: View {
    let updates: UpdateModel
    @AppStorage(UpdateSettings.sourceKey) private var source = UpdateSettings.sourceDefault.rawValue
    @AppStorage(UpdateSettings.folderPathKey) private var folderPath: String?
    @AppStorage(UpdateSettings.includeDebugKey) private var includeDebug = UpdateSettings.includeDebugDefault
    @AppStorage(UpdateSettings.checkAtLaunchKey) private var checkAtLaunch = UpdateSettings.checkAtLaunchDefault
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                LabeledContent("This build") {
                    Text("\(updates.running.label) · \(updates.running.commitLabel)").monospacedDigit().textSelection(.enabled)
                }
                Picker("Get builds from", selection: $source) {
                    Text("GitHub (\(GitHubReleasesSource.defaultRepository))").tag(UpdateSettings.Source.github.rawValue)
                    Text("A local folder").tag(UpdateSettings.Source.folder.rawValue)
                    Text("Off").tag(UpdateSettings.Source.off.rawValue)
                }
                if source == UpdateSettings.Source.folder.rawValue {
                    LabeledContent("Folder") {
                        HStack {
                            Text(folderPath ?? "None chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(Color.brandSecondary)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
                Text(sourceHelp).font(.caption).foregroundStyle(Color.brandSecondary)
            }
            Section {
                Toggle("Include Debug builds", isOn: $includeDebug)
                Text("Debug builds come from the same code with extra diagnostics and may be less polished. Off: only Release builds are offered.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
                Toggle("Check when Amaranth opens", isOn: $checkAtLaunch)
                    .disabled(source == UpdateSettings.Source.off.rawValue)
                Text("A newer build shows an Update Available button in the toolbar. Amaranth never installs anything unless you choose Install and Relaunch, and checks only when it opens or when you ask.")
                    .font(.caption).foregroundStyle(Color.brandSecondary)
            }
            Section {
                HStack {
                    Button("Check Now") {
                        openWindow(id: UpdateWindow.id)
                        updates.check(userInitiated: true)
                    }
                    .disabled(source == UpdateSettings.Source.off.rawValue)
                    if let at = updates.lastChecked {
                        Text("Last checked \(at.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Color.brandSecondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sourceHelp: String {
        switch UpdateSettings.Source(rawValue: source) ?? .github {
        case .github: "Asks GitHub for the list of published builds. Nothing about you or your meetings is sent. This and model downloads are Amaranth's only internet use."
        case .folder: "Builds published with scripts/publish.sh --local-only, for example on a shared drive. Nothing goes over the internet."
        case .off: "Amaranth never checks for builds. Use Check for Updates… later by choosing a source here."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds the release and debug build folders."
        if panel.runModal() == .OK, let url = panel.url { UpdateModel.choose(folder: url) }
    }
}
