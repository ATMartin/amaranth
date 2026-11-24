import SwiftUI
import AppKit
import Domain
import Storage
import MeetingAccess

/// Export Meetings… (T99, spec 0009 §4): selected meeting, a folder or the whole library as Markdown + JSON snapshots.
/// Scope and content first with a preview, then the destination, then progress (cancellable) and the outcome.
@MainActor @Observable
final class BulkExportModel {
    enum Scope: Hashable { case meeting(MeetingID), folder(FolderID), all }
    enum Phase: Equatable { case choosing, running(done: Int, total: Int), finished(BulkExport.Result, total: Int) }

    let store: MeetingStore
    var scope: Scope { didSet { refreshPreview() } }
    var content: BulkExport.Content = .notesAndTranscript
    private(set) var preview: BulkExport.Preview?
    private(set) var phase: Phase = .choosing
    private let cancelFlag = CancelFlag()

    init(store: MeetingStore, scope: Scope) {
        self.store = store
        self.scope = scope
        refreshPreview()
    }

    var accessScope: AccessScope {
        switch scope {
        case .meeting(let id): .meetings([id])
        case .folder(let f): .folders([f])
        case .all: .all
        }
    }

    func refreshPreview() {
        preview = try? BulkExport.preview(MeetingReader(store: store), scope: accessScope)
    }

    /// Asks for the destination, then exports off the main thread.
    func chooseDestinationAndRun() {
        guard let p = preview, p.count > 0 else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Amaranth writes an “amaranth” folder here, one folder per meeting."
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let reader = MeetingReader(store: store), ids = p.meetingIDs, content = content, flag = cancelFlag
        flag.reset()
        phase = .running(done: 0, total: ids.count)
        Task.detached(priority: .userInitiated) {
            let r = BulkExport.run(reader, meetings: ids, content: content, destination: dest, isCancelled: { flag.isSet }) { done, total in
                Task { @MainActor in if case .running = self.phase { self.phase = .running(done: done, total: total) } }
            }
            await MainActor.run { self.phase = .finished(r, total: ids.count) }
        }
    }

    func cancel() { cancelFlag.set() }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
        func reset() { lock.withLock { value = false } }
    }
}

struct BulkExportSheet: View {
    @State var model: BulkExportModel
    let meetingTitle: String?
    let folders: [Folder]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Meetings").font(.headline)
            switch model.phase {
            case .choosing: choosing
            case .running(let done, let total): running(done, total)
            case .finished(let r, let total): finished(r, total)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Meetings", selection: $model.scope) {
                if case .meeting(let id) = model.scope { Text("This meeting\(meetingTitle.map { ": \($0)" } ?? "")").tag(BulkExportModel.Scope.meeting(id)) }
                ForEach(folders) { Text("Folder: \($0.name)").tag(BulkExportModel.Scope.folder($0.id)) }
                Text("All meetings").tag(BulkExportModel.Scope.all)
            }
            Picker("Include", selection: $model.content) {
                Text("Notes and transcript").tag(BulkExport.Content.notesAndTranscript)
                Text("Notes only").tag(BulkExport.Content.notes)
            }
            .pickerStyle(.segmented)
            Text(model.preview.map { BulkExportWording.preview($0, content: model.content) } ?? "Couldn't read the library.")
                .font(.callout)
                .accessibilityIdentifier("bulk-export-preview")
            Text(BulkExportWording.snapshotExplanation)
                .font(.caption).foregroundStyle(Color.brandSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Folder…") { model.chooseDestinationAndRun() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((model.preview?.count ?? 0) == 0)
            }
        }
    }

    private func running(_ done: Int, _ total: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .accessibilityLabel("Export progress")
                .accessibilityValue("\(done) of \(total) meetings")
            Text("Exporting \(done) of \(total) meetings…").font(.callout)
            HStack {
                Spacer()
                Button("Stop", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(_ r: BulkExport.Result, _ total: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(BulkExportWording.title(r), systemImage: r.status == .complete ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text(BulkExportWording.summary(r, total: total)).font(.callout).fixedSize(horizontal: false, vertical: true)
            let issues = r.errors + r.kept
            if !issues.isEmpty && r.status != .failed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, i in
                            Text("\(i.title.map { "“\($0)”: " } ?? "")\(i.message)").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            HStack {
                if r.status != .failed {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.root]) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
